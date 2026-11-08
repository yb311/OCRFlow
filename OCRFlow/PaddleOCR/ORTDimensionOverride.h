#import <Foundation/Foundation.h>

@class ORTSessionOptions;

NS_ASSUME_NONNULL_BEGIN

/// Fixes a symbolic input dimension of every graph built with `options` to
/// one size — ONNX Runtime's free-dimension override, which its
/// Objective-C binding does not expose.
///
/// Core ML only runs a graph on the GPU when every input shape is known up
/// front; with a symbolic dimension left open it falls back to a path that
/// is several times slower than ONNX Runtime's own CPU kernels.
FOUNDATION_EXTERN BOOL OCRFlowFixInputDimension(ORTSessionOptions *options, NSString *name, int64_t value,
                                                NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
