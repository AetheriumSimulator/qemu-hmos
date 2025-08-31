#ifndef CUSTOM_STDDEF_H
#define CUSTOM_STDDEF_H

// 定义nullptr_t以解决编译错误
#if !defined(nullptr_t)
typedef decltype(nullptr) nullptr_t;
#endif

#endif // CUSTOM_STDDEF_H
