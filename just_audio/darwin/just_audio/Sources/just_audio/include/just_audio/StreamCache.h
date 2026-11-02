#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

/// Disk cache for progressive streams, served to AVPlayer via a resource loader.
///
/// Stores only the byte ranges the player asks for. AVFoundation has no
/// equivalent of ExoPlayer's CacheDataSource, so the range bookkeeping lives
/// here. All state is confined to one serial queue.
@interface StreamCache : NSObject

+ (instancetype)shared;
- (void)configureWithMaxBytes:(long long)maxBytes;

/// An asset that loads through the cache, or nil when [uri] should bypass it.
- (AVURLAsset *)assetForURI:(NSString *)uri options:(NSDictionary *)options;

- (void)sizeWithCompletion:(void (^)(long long))completion;
- (void)urlsWithCompletion:(void (^)(NSArray<NSString *> *))completion;
- (void)clearKeeping:(NSArray<NSString *> *)keep includeInUse:(BOOL)includeInUse completion:(void (^)(void))completion;
- (void)removeURL:(NSString *)url completion:(void (^)(void))completion;

@end
