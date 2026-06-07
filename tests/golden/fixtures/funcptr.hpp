#pragma once

typedef void (*GLFWglproc)(void);
typedef int (*Comparator)(const int* a, const int* b);
typedef void (*GLFWmousebuttonfun)(GLFWwindow* window, int button, int action);
using Handler = void (*)(int code);
using PlainAlias = uint32_t;
