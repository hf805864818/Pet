//
//  PDNative_AXCompat.h — iOS 上不提供 ApplicationServices 头，
//  这里只补类型声明；所有 AX 符号在运行时通过 dlsym 解析。
//
#ifndef PDNATIVE_AXCOMPAT_H
#define PDNATIVE_AXCOMPAT_H

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

#ifndef PDNATIVE_AXUIELEMENTREF_TYPEDEF
#define PDNATIVE_AXUIELEMENTREF_TYPEDEF
typedef struct __AXUIElement *AXUIElementRef;
typedef struct __AXValue     *AXValueRef;
typedef int32_t               AXError;
typedef uint32_t              AXValueType;
typedef uint32_t              AXCopyMultipleAttributeOptions;
#endif

#endif
