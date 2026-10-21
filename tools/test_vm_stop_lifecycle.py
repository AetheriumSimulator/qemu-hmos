"""Exercise the actual StopVm entrypoint and its production lifecycle helper.

Native stop ownership uses deterministic thread/QMP/platform doubles. Watchdog
cases use actual host runner threads and join, with a controlled clock/QMP.
No QEMU, phone, microphone, NativeWindow or user world is accessed.
"""
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / "entry/src/main/cpp"
SOURCE = Path(os.environ.get("AETHER_NAPI_SOURCE", CPP / "napi_init.cpp"))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def function(source, signature):
    match = re.search(signature + r"\s*\{", source)
    if not match:
        raise AssertionError("Production function missing: " + signature)
    # Braces inside QMP JSON string literals are not C++ scope delimiters.
    tokens = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    masked = re.sub(tokens, lambda item: " " * len(item.group()), source)
    depth = 0
    for offset in range(match.end() - 1, len(source)):
        if masked[offset] == "{":
            depth += 1
        elif masked[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():offset + 1]
    raise AssertionError("Unclosed function")


PREFIX = r'''
#include "vm_lifecycle.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>
'''


def compile_and_run(body, *args):
    with tempfile.TemporaryDirectory(prefix="aether-stop-") as directory:
        root = Path(directory)
        source = root / "test.cpp"
        binary = root / "test"
        source.write_text(PREFIX + body, encoding="utf-8")
        subprocess.run(["g++", "-std=c++17", "-pthread", "-Wall", "-Wextra",
                        "-Wno-unused-function", "-I", str(CPP), str(source),
                        "-o", str(binary)], check=True)
        result = subprocess.run([str(binary), *args], check=False, timeout=15, cwd=root,
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"host fixture exited {result.returncode}:\n{result.stdout}{result.stderr}")
        return result.stdout


NATIVE_FIXTURE = r'''
using napi_env = void*;
using napi_callback_info = void*;
using napi_value = int;
static void napi_get_cb_info(napi_env, napi_callback_info, size_t*, napi_value* a, void*, void*) { *a=1; }
static bool NapiGetStringUtf8(napi_env, napi_value, std::string& name) { name="world"; return true; }
static void napi_get_boolean(napi_env, bool value, napi_value* out) { *out=value; }
static std::vector<std::function<void()>> jobs;
static bool failThreadCreation=false;
static int joins=0;
struct TestThread {
    bool owned=false;
    TestThread()=default;
    template<class F> explicit TestThread(F body) {
        if (failThreadCreation) throw std::runtime_error("injected thread creation failure");
        owned=true;
        auto task=std::make_shared<F>(std::move(body));
        jobs.emplace_back([task] { (*task)(); });
    }
    static TestThread Runner() { TestThread t; t.owned=true; return t; }
    TestThread(TestThread&& other) noexcept : owned(other.owned) { other.owned=false; }
    TestThread& operator=(TestThread&& other) noexcept {
        assert(!owned); owned=other.owned; other.owned=false; return *this;
    }
    ~TestThread() { assert(!owned && "lost joinable thread ownership"); }
    bool joinable() const { return owned; }
    void join() { assert(owned); owned=false; ++joins; }
    void detach() { owned=false; }
};
static std::map<std::string,TestThread> g_vmThreads;
static std::map<std::string,std::string> g_vmStates;
static std::mutex g_vmMutex, g_vmStateMutex;
static std::atomic<bool> g_qemu_initialized {true};
static constexpr int SHUTDOWN_CAUSE_HOST=0;
struct Microphone { void Stop(const std::string&) {} } g_microphone;
enum class VmStartError { LOOP_CRASHED };
static void SetLastError(VmStartError,const std::string&,const std::string&,const std::string&,const std::string&) {}
static void UpdateVMStatus(const std::string& name,const std::string& state) { g_vmStates[name]=state; }
static void WriteLog(const std::string&,const std::string&) {}
static void HilogPrint(const std::string&) {}
static void qemu_system_shutdown_request(int) {}
static std::string QueryVmStatusViaQmp(const std::string&) { return "stopped"; }
static bool SendVmQmpQuit(const std::string&) { throw std::runtime_error("QMP must not run in ownership fixture"); }
'''


class VmStopTests(unittest.TestCase):
    def test_actual_native_stop_has_one_owner(self):
        source = SOURCE.read_text(encoding="utf-8")
        migrated = "static bool RequestVmStop(" in source
        body = NATIVE_FIXTURE
        if migrated:
            body += 'static std::map<std::string,std::shared_ptr<aether::VmLifecycle>> g_vmRunning;\n'
            body += function(source, r"static bool RequestVmStop\(const std::string& vmName, const std::string& logPath\)")
        else:
            body += 'static std::map<std::string,std::atomic<bool>*> g_vmRunning;\n'
        body += function(source, r"static napi_value StopVm\(napi_env env, napi_callback_info info\)")
        body = body.replace("std::thread", "TestThread")
        setup = ('auto run=std::make_shared<aether::VmLifecycle>(); g_vmRunning["world"]=run;'
                 if migrated else 'std::atomic<bool> running(true); g_vmRunning["world"]=&running;')
        body += '\nint main() {\n' + setup + r'''
            g_vmThreads.emplace("world",TestThread::Runner());
            assert(StopVm(nullptr,nullptr)==1);
            assert(StopVm(nullptr,nullptr)==1);
            assert(jobs.size()==1 && "duplicate stop must not create another owner");
'''
        if migrated:
            body += r'''
            assert(run->IsActive());
            assert(g_vmThreads["world"].joinable());
            run->Complete(0); // Deterministic runner-return boundary.
            auto job=std::move(jobs.back()); jobs.clear(); job();
            assert(joins==1 && !run->BlocksStart() && g_vmThreads.empty());
            std::cout << "PASS actual StopVm idempotence and exclusive runner join\n";
'''
        body += '}\n'
        print(compile_and_run(body), end="")

    @unittest.skipIf("AETHER_NAPI_SOURCE" in os.environ, "baseline has no safe monitor-construction recovery")
    def test_native_monitor_creation_failure_keeps_runner(self):
        source = SOURCE.read_text(encoding="utf-8")
        body = NATIVE_FIXTURE + 'static std::map<std::string,std::shared_ptr<aether::VmLifecycle>> g_vmRunning;\n'
        body += function(source, r"static bool RequestVmStop\(const std::string& vmName, const std::string& logPath\)")
        body += function(source, r"static napi_value StopVm\(napi_env env, napi_callback_info info\)")
        body = body.replace("std::thread", "TestThread")
        body += r'''
        int main() {
            auto run=std::make_shared<aether::VmLifecycle>(); g_vmRunning["world"]=run;
            g_vmThreads.emplace("world",TestThread::Runner());
            failThreadCreation=true;
            assert(StopVm(nullptr,nullptr)==0);
            assert(jobs.empty() && g_vmThreads["world"].joinable() && run->IsActive());
            assert(run->Read().error.find("injected thread creation failure")!=std::string::npos);
            failThreadCreation=false;
            assert(StopVm(nullptr,nullptr)==1 && jobs.size()==1);
            run->Complete(0);
            auto job=std::move(jobs.back()); jobs.clear(); job();
            assert(joins==1 && run->Read().status=="failed");
            std::cout << "PASS monitor creation failure retains runner and permits stop retry\n";
        }
'''
        print(compile_and_run(body), end="")

    @unittest.skipIf("AETHER_NAPI_SOURCE" in os.environ, "new production helper")
    def test_watchdog_and_failure_boundaries(self):
        body = r'''
        int main(int argc,char** argv) {
            assert(argc==2); const std::string name=argv[1];
            aether::VmLifecycle run;
            assert(run.MarkRunning() && run.ClaimStop() && !run.ClaimStop());
            std::promise<void> release, finished;
            auto gate=release.get_future(); auto done=finished.get_future();
            bool released=false;
            std::thread runner([&] { gate.wait(); run.Complete(0); finished.set_value(); });
            auto finish=[&] { if(!released) { released=true; release.set_value(); done.wait(); } };
            int64_t clock=0; int quits=0, reports=0;
            if(name=="startup-failure") {
                run.Fail("startup failed"); run.Fail("startup failed");
                assert(!run.MarkRunning() && run.Read().error=="startup failed");
            }
            aether::WaitForVmStop(run,[&] {
                ++quits;
                if(name=="exit-during-quit") { finish(); return false; }
                if(name=="retry" && quits==2) { finish(); return true; }
                if(name=="quit-crosses-deadline") { clock=7000; return false; }
                return name=="accepted-hung";
            },[&] { return clock; },[&] {
                clock+=1000;
                if(name=="grace" && clock==1000) finish();
                if((name=="timeout" || name=="accepted-hung" || name=="startup-failure" ||
                    name=="quit-crosses-deadline") && clock>=5000) finish();
            },[&](const std::string&) {
                ++reports; assert(run.IsActive() && run.Read().status=="stopping");
            },2000,2000);
            runner.join();
            assert(!run.IsActive());
            if(name=="retry") assert(quits==2 && reports==0 && run.Read().status=="stopped");
            if(name=="grace") assert(quits==0 && reports==0);
            if(name=="exit-during-quit") assert(quits==1 && reports==0);
            if(name=="accepted-hung") assert(quits==1 && reports==1 && run.Read().status=="failed");
            if(name=="timeout") assert(quits>=3 && reports==1 && run.Read().status=="failed");
            if(name=="quit-crosses-deadline") assert(quits==1 && reports==1 && run.Read().status=="failed");
            if(name=="startup-failure") assert(reports==1 && run.Read().error.find("startup failed")==0);
            run.Fail("late failure"); assert(!run.IsActive() && run.Read().status=="failed");
            std::cout << "PASS " << name << ": real runner returned and joined\n";
        }
'''
        for case in ("retry", "timeout", "accepted-hung", "grace", "exit-during-quit", "startup-failure", "quit-crosses-deadline"):
            with self.subTest(case=case):
                print(compile_and_run(body, case), end="")

    @unittest.skipIf("AETHER_NAPI_SOURCE" in os.environ, "new status behavior")
    def test_disconnected_qmp_is_unknown(self):
        source = SOURCE.read_text(encoding="utf-8")
        body = 'static void HilogPrint(const std::string&) {}\n'
        body += 'static int DeniedConnect(int,const sockaddr*,socklen_t) { return -1; }\n'
        body += function(source, r"static std::string QueryVmStatusViaQmp\(const std::string& vmName\)").replace('connect(sock,', 'DeniedConnect(sock,')
        body += '\nint main() { assert(QueryVmStatusViaQmp("fixture")=="unknown"); }\n'
        compile_and_run(body)

    @unittest.skipIf("AETHER_NAPI_SOURCE" in os.environ, "new QMP transport")
    def test_stop_qmp_acknowledgement(self):
        source = SOURCE.read_text(encoding="utf-8")
        body = function(source, r"static bool ReadStopQmpReply\(int fd, const std::string& id, bool greeting\)")
        body += function(source, r"static bool SendVmQmpQuit\(const std::string& socketPath\)")
        body += r'''
        int main() {
            for (bool reject : {true,false}) {
                const std::string path="./qmp-fixture.sock";
                int listener=socket(AF_UNIX,SOCK_STREAM,0); assert(listener>=0);
                sockaddr_un address {}; address.sun_family=AF_UNIX;
                std::memcpy(address.sun_path,path.c_str(),path.size()+1);
                assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
                assert(listen(listener,1)==0);
                std::thread peer([&] {
                    int fd=accept(listener,nullptr,nullptr); assert(fd>=0);
                    auto write=[&](const std::string& value) {
                        assert(send(fd,value.data(),value.size(),MSG_NOSIGNAL)==static_cast<ssize_t>(value.size()));
                    };
                    write("{\"QMP\":"); write("{}}\n");
                    auto read=[&] {
                        std::string command; char byte;
                        do { assert(recv(fd,&byte,1,0)==1); command+=byte; } while(byte!='\n');
                        return command;
                    };
                    assert(read().find("aether-stop-cap")!=std::string::npos);
                    write("{\"event\":\"STOP\"}\n{\"return\":{},\"id\":\"aether-stop-cap\"}\n");
                    assert(read().find("aether-stop-quit")!=std::string::npos);
                    write(reject ? "{\"error\":{\"desc\":\"fixture\"},\"id\":\"aether-stop-quit\"}\n"
                                 : "{\"return\":{},\"id\":\"aether-stop-quit\"}\n");
                    close(fd);
                });
                assert(SendVmQmpQuit(path)==!reject);
                peer.join(); close(listener); unlink(path.c_str());
            }
            std::cout << "PASS actual QMP framing, event filtering and quit error/ack\n";
        }
'''
        print(compile_and_run(body), end="")


if __name__ == "__main__":
    unittest.main()
