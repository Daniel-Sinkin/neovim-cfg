auto debug_messenger_create_info() -> VkDebugUtilsMessengerCreateInfoEXT
{
    return VkDebugUtilsMessengerCreateInfoEXT{
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = {},
        .flags = VkFlags{0},
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                           | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
                       | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                       | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debug_callback,
        .pUserData = nullptr,
    };
}

auto from_locals() -> VkDebugUtilsMessengerCreateInfoEXT
{
    return VkDebugUtilsMessengerCreateInfoEXT{
        .messageSeverity = message_severity,
        .messageType = message_type,
        .pApplicationInfo = &application_info,
        .pUserData = user_data,
    };
}
