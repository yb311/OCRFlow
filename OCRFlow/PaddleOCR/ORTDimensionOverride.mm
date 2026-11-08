#import "ORTDimensionOverride.h"

#import "ort_session.h"
#include <onnxruntime/onnxruntime_cxx_api.h>

// The binding keeps the C++ options object behind this accessor, declared in
// its internal header; the package is pinned, so the method is too.
@interface ORTSessionOptions ()
- (Ort::SessionOptions &)CXXAPIOrtSessionOptions;
@end

BOOL OCRFlowFixInputDimension(ORTSessionOptions *options, NSString *name, int64_t value,
                              NSError **error) {
    try {
        [options CXXAPIOrtSessionOptions].AddFreeDimensionOverrideByName(name.UTF8String, value);
        return YES;
    } catch (const Ort::Exception &exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCRFlow.ONNXRuntime"
                                         code:exception.GetOrtErrorCode()
                                     userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        }
        return NO;
    }
}
