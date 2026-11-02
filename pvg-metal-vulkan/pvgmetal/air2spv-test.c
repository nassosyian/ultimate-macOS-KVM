/*
 * air2spv-test: translate AIR bitcode (.bc) or metallib files to SPIR-V and validate each module
 * with vkCreateShaderModule under the Khronos validation layer.
 *
 * Usage: air2spv-test [-o OUTDIR] FILE...
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

#include "air2spv.h"

static int validation_errors;

static VKAPI_ATTR VkBool32 VKAPI_CALL on_message(VkDebugUtilsMessageSeverityFlagBitsEXT sev,
                                                 VkDebugUtilsMessageTypeFlagsEXT type,
                                                 const VkDebugUtilsMessengerCallbackDataEXT *d,
                                                 void *user)
{
    (void)type;
    (void)user;
    if (sev >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        validation_errors++;
        fprintf(stderr, "    VALIDATION: %s\n", d->pMessage);
    }
    return VK_FALSE;
}

static VkInstance instance;
static VkDevice device;
static VkDebugUtilsMessengerEXT messenger;

static int vk_init(void)
{
    const char *layers[] = { "VK_LAYER_KHRONOS_validation" };
    const char *exts[] = { VK_EXT_DEBUG_UTILS_EXTENSION_NAME };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "air2spv-test", .apiVersion = VK_API_VERSION_1_3 };
    VkDebugUtilsMessengerCreateInfoEXT dbg = {
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT,
        .pfnUserCallback = on_message,
    };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pNext = &dbg,
                                 .pApplicationInfo = &app, .enabledLayerCount = 1,
                                 .ppEnabledLayerNames = layers, .enabledExtensionCount = 1,
                                 .ppEnabledExtensionNames = exts };
    VkPhysicalDevice pd[8];
    uint32_t npd = 8;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                    .queueFamilyIndex = 0, .queueCount = 1,
                                    .pQueuePriorities = &prio };
    /* fragment barycentrics and PrimitiveId, as pvg-gpu.c enables them when present */
    const char *dev_exts[] = { VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME };
    VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR fbary = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR,
        .fragmentShaderBarycentric = VK_TRUE };
    VkPhysicalDeviceVulkan13Features f13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .shaderDemoteToHelperInvocation = VK_TRUE };
    VkPhysicalDeviceVulkan12Features f12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &f13,
        .bufferDeviceAddress = VK_TRUE, .scalarBlockLayout = VK_TRUE, .shaderInt8 = VK_TRUE,
        .shaderFloat16 = VK_TRUE, .storageBuffer8BitAccess = VK_TRUE,
        /* argument buffers (A2S_INDIRECT_SET), as pvg-gpu.c enables them */
        .runtimeDescriptorArray = VK_TRUE, .descriptorBindingPartiallyBound = VK_TRUE,
        .shaderSampledImageArrayNonUniformIndexing = VK_TRUE,
        .shaderStorageImageArrayNonUniformIndexing = VK_TRUE };
    VkPhysicalDeviceFeatures2 f2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12,
        .features = { .shaderInt64 = VK_TRUE, .shaderInt16 = VK_TRUE,
                      .fragmentStoresAndAtomics = VK_TRUE, .shaderFloat64 = VK_TRUE,
                      .geometryShader = VK_TRUE } };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2,
                               .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    PFN_vkCreateDebugUtilsMessengerEXT mk;

    if (vkCreateInstance(&ici, NULL, &instance) != VK_SUCCESS) {
        fprintf(stderr, "vkCreateInstance failed (validation layer missing?)\n");
        return -1;
    }
    mk = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(instance,
                                                                  "vkCreateDebugUtilsMessengerEXT");
    if (mk) {
        mk(instance, &dbg, NULL, &messenger);
    }
    if (vkEnumeratePhysicalDevices(instance, &npd, pd) != VK_SUCCESS || !npd) {
        fprintf(stderr, "no Vulkan device\n");
        return -1;
    }
    {
        VkExtensionProperties ext[512];
        uint32_t next = 512;

        vkEnumerateDeviceExtensionProperties(pd[0], NULL, &next, ext);
        for (uint32_t i = 0; i < next; i++) {
            if (!strcmp(ext[i].extensionName, dev_exts[0])) {
                f13.pNext = &fbary;
                dci.enabledExtensionCount = 1;
                dci.ppEnabledExtensionNames = dev_exts;
            }
        }
    }
    if (vkCreateDevice(pd[0], &dci, NULL, &device) != VK_SUCCESS) {
        fprintf(stderr, "vkCreateDevice failed\n");
        return -1;
    }
    return 0;
}

static void *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    void *buf;

    if (!f) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    rewind(f);
    buf = malloc(*len);
    if (fread(buf, 1, *len, f) != *len) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    return buf;
}

int main(int argc, char **argv)
{
    const char *outdir = NULL;
    int ok = 0, bad_translate = 0, bad_validate = 0, first = 1;

    if (argc > 2 && !strcmp(argv[1], "-o")) {
        outdir = argv[2];
        first = 3;
    }
    if (vk_init()) {
        return 2;
    }
    for (int i = first; i < argc; i++) {
        size_t len, bclen;
        void *data = slurp(argv[i], &len);
        const void *bc = data;
        A2SResult r = { 0 };
        VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
        VkShaderModule sm;
        int before = validation_errors;
        const char *base = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];

        if (!data) {
            fprintf(stderr, "%s: cannot read\n", argv[i]);
            continue;
        }
        bclen = len;
        if (len > 4 && !memcmp(data, "MTLB", 4)) {
            bc = air2spv_metallib_bitcode(data, len, &bclen);
        }
        if (!bc || air2spv_translate(bc, bclen, &r)) {
            printf("FAIL-TRANSLATE %-24s %s\n", base, bc ? r.error : "no bitcode");
            bad_translate++;
            free(data);
            continue;
        }
        smci.codeSize = r.nwords * 4;
        smci.pCode = r.spirv;
        if (vkCreateShaderModule(device, &smci, NULL, &sm) != VK_SUCCESS) {
            validation_errors++;
        } else {
            vkDestroyShaderModule(device, sm, NULL);
        }
        if (outdir) {
            char path[512];
            FILE *f;

            snprintf(path, sizeof(path), "%s/%s.spv", outdir, base);
            f = fopen(path, "wb");
            if (f) {
                fwrite(r.spirv, 4, r.nwords, f);
                fclose(f);
            }
        }
        if (validation_errors != before) {
            printf("FAIL-VALIDATE  %-24s %s %s\n", base, r.stage ? "frag" : "vert", r.entry);
            bad_validate++;
        } else {
            printf("OK             %-24s %s %-28s words=%zu bufs=%#x tex=%#x smp=%#x vary=%d\n",
                   base, r.stage ? "frag" : "vert", r.entry, r.nwords, r.buffer_mask,
                   r.texture_mask, r.sampler_mask, r.nvaryings);
            ok++;
        }
        free(r.spirv);
        free(data);
    }
    printf("\n%d ok, %d translate failures, %d validation failures\n", ok, bad_translate,
           bad_validate);
    vkDestroyDevice(device, NULL);
    if (messenger) {
        ((PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
            instance, "vkDestroyDebugUtilsMessengerEXT"))(instance, messenger, NULL);
    }
    vkDestroyInstance(instance, NULL);
    return bad_translate || bad_validate;
}
