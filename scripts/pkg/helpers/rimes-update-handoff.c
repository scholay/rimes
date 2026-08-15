#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

// This tiny helper is built from the incoming package, signed, and executed by
// preinstall before PackageKit replaces the old app. It deliberately has no
// dependency on an old ETInput binary understanding a newly introduced flag.

static CFStringRef string_property(TISInputSourceRef source, CFStringRef key) {
    return (CFStringRef)TISGetInputSourceProperty(source, key);
}

static bool bool_property(TISInputSourceRef source, CFStringRef key) {
    CFTypeRef value = TISGetInputSourceProperty(source, key);
    return value != NULL
        && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value);
}

static bool is_rimes_source(TISInputSourceRef source) {
    const CFStringRef current_id = CFSTR("com.isaac.inputmethod.RimeBuffer");
    const CFStringRef legacy_id = CFSTR("com.isaac.inputmethod.ETInput");
    CFStringRef bundle_id = string_property(source, kTISPropertyBundleID);
    if (bundle_id != NULL
        && (CFEqual(bundle_id, current_id) || CFEqual(bundle_id, legacy_id))) {
        return true;
    }
    CFStringRef source_id = string_property(source, kTISPropertyInputSourceID);
    if (source_id == NULL) {
        return false;
    }
    return CFEqual(source_id, current_id)
        || CFEqual(source_id, legacy_id)
        || CFStringHasPrefix(source_id, CFSTR("com.isaac.inputmethod.RimeBuffer."))
        || CFStringHasPrefix(source_id, CFSTR("com.isaac.inputmethod.ETInput."));
}

static bool current_source_is_safe(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (current == NULL) {
        return false;
    }
    bool safe = !is_rimes_source(current);
    CFRelease(current);
    return safe;
}

static bool try_fallback(TISInputSourceRef candidate) {
    if (candidate == NULL || is_rimes_source(candidate)
        || !bool_property(candidate, kTISPropertyInputSourceIsEnabled)
        || !bool_property(candidate, kTISPropertyInputSourceIsASCIICapable)
        || !bool_property(candidate, kTISPropertyInputSourceIsSelectCapable)) {
        return false;
    }
    OSStatus status = TISSelectInputSource(candidate);
    if (status != noErr) {
        return false;
    }
    for (int attempt = 0; attempt < 20; attempt++) {
        if (current_source_is_safe()) {
            return true;
        }
        usleep(100000);
    }
    return false;
}

int main(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (current == NULL) {
        fprintf(stderr, "RIMES handoff: current input source is unavailable\n");
        return 1;
    }
    bool already_safe = !is_rimes_source(current);
    CFRelease(current);
    if (already_safe) {
        printf("RIMES handoff: current input source is already safe\n");
        return 0;
    }

    TISInputSourceRef layout = TISCopyCurrentKeyboardLayoutInputSource();
    if (try_fallback(layout)) {
        CFRelease(layout);
        printf("RIMES handoff: selected the current keyboard layout\n");
        return 0;
    }
    if (layout != NULL) {
        CFRelease(layout);
    }

    TISInputSourceRef ascii = TISCopyCurrentASCIICapableKeyboardInputSource();
    if (try_fallback(ascii)) {
        CFRelease(ascii);
        printf("RIMES handoff: selected an ASCII-capable input source\n");
        return 0;
    }
    if (ascii != NULL) {
        CFRelease(ascii);
    }

    CFArrayRef enabled = TISCreateInputSourceList(NULL, false);
    if (enabled != NULL) {
        CFIndex count = CFArrayGetCount(enabled);
        for (CFIndex index = 0; index < count; index++) {
            TISInputSourceRef candidate = (TISInputSourceRef)CFArrayGetValueAtIndex(
                enabled,
                index
            );
            if (try_fallback(candidate)) {
                CFRelease(enabled);
                printf("RIMES handoff: selected an enabled ASCII source\n");
                return 0;
            }
        }
        CFRelease(enabled);
    }

    fprintf(stderr, "RIMES handoff: no safe fallback could be selected\n");
    return 1;
}
