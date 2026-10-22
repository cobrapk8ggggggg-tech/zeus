// From OpenMinis NativeOffloadUtils.m, pinned at 6339bfcb2519.
#import "OpenMinisBridge.h"
BOOL noff_try_objc(void (NS_NOESCAPE ^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *exception) { return NO; }
}
