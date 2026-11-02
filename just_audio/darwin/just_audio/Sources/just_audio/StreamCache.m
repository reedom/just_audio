#import "./include/just_audio/StreamCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

// AVFoundation only consults the resource loader for schemes it cannot load.
static NSString *const kSchemePrefix = @"justaudiocache-";
static const NSUInteger kDeliveryChunk = 256 * 1024;
static const long long kEvictInterval = 4 * 1024 * 1024;
static const long long kMetaSaveInterval = 1024 * 1024;
static char kLoaderKey;

#pragma mark - Entry

/// One stream on disk: a sparse data file plus the ranges known to be filled.
/// A range enters the metadata only after its bytes were written, so a crash
/// can lose ranges but never claim bytes that are not there.
@interface StreamCacheEntry : NSObject
@property(nonatomic, copy) NSString *url;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic) long long total;
@property(nonatomic, copy) NSString *validator;
@property(nonatomic, copy) NSString *ifRange;
@property(nonatomic, copy) NSString *contentType;
@property(nonatomic) BOOL rangesSupported;
@property(nonatomic) BOOL hasMetadata;
@property(nonatomic) BOOL validated;
@property(nonatomic) BOOL writable;
@property(nonatomic) NSTimeInterval lastAccess;
@property(nonatomic) long long unsavedBytes;
@property(nonatomic) NSInteger refCount;
@property(nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *ranges;
@property(nonatomic, strong) NSFileHandle *handle;
@end

@implementation StreamCacheEntry

- (NSString *)dataPath { return [_directory stringByAppendingPathComponent:@"data"]; }
- (NSString *)metaPath { return [_directory stringByAppendingPathComponent:@"meta.plist"]; }

- (instancetype)initWithURL:(NSString *)url directory:(NSString *)directory {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _url = [url copy];
    _directory = [directory copy];
    _ranges = [NSMutableArray array];
    _writable = YES;
    _rangesSupported = YES;
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[self metaPath]];
    // Caches can be purged by the OS file by file, so metadata alone proves nothing.
    if (meta && [[NSFileManager defaultManager] fileExistsAtPath:[self dataPath]]) {
        _total = [meta[@"total"] longLongValue];
        _validator = meta[@"validator"];
        _ifRange = meta[@"ifRange"];
        _contentType = meta[@"contentType"];
        _rangesSupported = [meta[@"rangesSupported"] boolValue];
        _lastAccess = [meta[@"lastAccess"] doubleValue];
        _ranges = [meta[@"ranges"] mutableCopy] ?: [NSMutableArray array];
        _hasMetadata = YES;
    }
    return self;
}

- (long long)storedBytes {
    long long sum = 0;
    for (NSArray<NSNumber *> *r in _ranges) sum += r[1].longLongValue - r[0].longLongValue;
    return sum;
}

/// Bytes available from [offset] without touching the network.
- (long long)cachedRunFrom:(long long)offset {
    for (NSArray<NSNumber *> *r in _ranges) {
        if (r[0].longLongValue <= offset && offset < r[1].longLongValue) return r[1].longLongValue - offset;
    }
    return 0;
}

/// Where the hole containing [offset] ends, so a fetch never re-reads stored bytes.
- (long long)holeEndFrom:(long long)offset limit:(long long)limit {
    for (NSArray<NSNumber *> *r in _ranges) {
        long long start = r[0].longLongValue;
        if (offset < start) return MIN(start, limit);
    }
    return limit;
}

- (void)addRangeFrom:(long long)start to:(long long)end {
    NSMutableArray *merged = [NSMutableArray array];
    for (NSArray<NSNumber *> *r in _ranges) {
        long long a = r[0].longLongValue, b = r[1].longLongValue;
        if (b < start || end < a) {
            [merged addObject:r];
        } else {
            start = MIN(start, a);
            end = MAX(end, b);
        }
    }
    [merged addObject:@[ @(start), @(end) ]];
    [merged sortUsingComparator:^NSComparisonResult(NSArray<NSNumber *> *x, NSArray<NSNumber *> *y) {
        return [x[0] compare:y[0]];
    }];
    _ranges = merged;
}

- (NSFileHandle *)openHandle {
    if (_handle) return _handle;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:[self dataPath]]) {
        [fm createFileAtPath:[self dataPath] contents:nil attributes:nil];
    }
    _handle = [NSFileHandle fileHandleForUpdatingAtPath:[self dataPath]];
    return _handle;
}

- (void)closeHandle {
    if (@available(iOS 13.0, macOS 10.15, *)) [_handle closeAndReturnError:nil];
    _handle = nil;
}

- (NSData *)readFrom:(long long)offset length:(NSUInteger)length {
    NSFileHandle *h = [self openHandle];
    if (!h) return nil;
    if (@available(iOS 13.4, macOS 10.15.4, *)) {
        if (![h seekToOffset:offset error:nil]) return nil;
        return [h readDataUpToLength:length error:nil];
    }
    return nil;
}

/// Returns NO when the disk refuses the write. Playback continues uncached.
- (BOOL)writeData:(NSData *)data at:(long long)offset {
    if (!_writable) return NO;
    NSFileHandle *h = [self openHandle];
    BOOL ok = NO;
    if (h) {
        if (@available(iOS 13.4, macOS 10.15.4, *)) {
            ok = [h seekToOffset:offset error:nil] && [h writeData:data error:nil];
        }
    }
    if (!ok) {
        _writable = NO;
        return NO;
    }
    [self addRangeFrom:offset to:offset + (long long)data.length];
    _unsavedBytes += data.length;
    if (kMetaSaveInterval <= _unsavedBytes) [self saveMeta];
    return YES;
}

- (void)saveMeta {
    _unsavedBytes = 0;
    if (!_hasMetadata) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"url"] = _url;
    meta[@"total"] = @(_total);
    meta[@"rangesSupported"] = @(_rangesSupported);
    meta[@"lastAccess"] = @(_lastAccess);
    meta[@"ranges"] = _ranges;
    if (_validator) meta[@"validator"] = _validator;
    if (_ifRange) meta[@"ifRange"] = _ifRange;
    if (_contentType) meta[@"contentType"] = _contentType;
    [meta writeToFile:[self metaPath] atomically:YES];
}

- (void)forgetBytes {
    [_ranges removeAllObjects];
    [self closeHandle];
    [[NSFileManager defaultManager] removeItemAtPath:[self dataPath] error:nil];
    [self saveMeta];
}

- (void)reset {
    [_ranges removeAllObjects];
    _hasMetadata = NO;
    _validated = NO;
    _validator = nil;
    _ifRange = nil;
    _total = 0;
    _unsavedBytes = 0;
    [self closeHandle];
    [[NSFileManager defaultManager] removeItemAtPath:_directory error:nil];
}

@end

#pragma mark - Operation

@interface StreamCacheOp : NSObject
@property(nonatomic, strong) AVAssetResourceLoadingRequest *request;
@property(nonatomic, strong) StreamCacheEntry *entry;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic) BOOL probing;
@property(nonatomic) BOOL finished;
@property(nonatomic) long long offset;
@property(nonatomic) long long end;
@end

@implementation StreamCacheOp
@end

#pragma mark - Loader

/// Owned by its asset, so the stream counts as in use exactly as long as the player holds it.
@interface StreamCacheLoader : NSObject <AVAssetResourceLoaderDelegate>
@property(nonatomic, strong) StreamCacheEntry *entry;
@end

@interface StreamCache () <NSURLSessionDataDelegate>
- (void)startRequest:(AVAssetResourceLoadingRequest *)request entry:(StreamCacheEntry *)entry;
- (void)cancelRequest:(AVAssetResourceLoadingRequest *)request;
- (void)releaseEntry:(StreamCacheEntry *)entry;
@end

@implementation StreamCacheLoader

- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    [[StreamCache shared] startRequest:request entry:_entry];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request {
    [[StreamCache shared] cancelRequest:request];
}

- (void)dealloc {
    [[StreamCache shared] releaseEntry:_entry];
}

@end

#pragma mark - Cache

@implementation StreamCache {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSString *_root;
    long long _maxBytes;
    long long _bytesSinceEvict;
    NSMutableDictionary<NSString *, StreamCacheEntry *> *_entries;
    NSMutableArray<StreamCacheOp *> *_ops;
}

+ (instancetype)shared {
    static StreamCache *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[StreamCache alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _queue = dispatch_queue_create("com.ryanheise.just_audio.stream_cache", DISPATCH_QUEUE_SERIAL);
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    _root = [caches stringByAppendingPathComponent:@"stream_audio_cache"];
    _entries = [NSMutableDictionary dictionary];
    _ops = [NSMutableArray array];
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.underlyingQueue = _queue;
    delegateQueue.maxConcurrentOperationCount = 1;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    // The store below is the cache; URLCache would keep a second copy.
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    return self;
}

- (void)configureWithMaxBytes:(long long)maxBytes {
    dispatch_async(_queue, ^{
        self->_maxBytes = maxBytes;
        [self evict];
    });
}

- (NSString *)directoryForURL:(NSString *)url {
    NSData *bytes = [url dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
    return [_root stringByAppendingPathComponent:name];
}

- (AVURLAsset *)assetForURI:(NSString *)uri options:(NSDictionary *)options {
    __block long long maxBytes;
    dispatch_sync(_queue, ^{ maxBytes = self->_maxBytes; });
    if (maxBytes <= 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:uri];
    NSString *scheme = components.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    // A playlist's segments are resolved against the playlist URL, past any loader.
    if ([components.path.lowercaseString hasSuffix:@".m3u8"]) return nil;
    components.scheme = [kSchemePrefix stringByAppendingString:scheme];
    NSURL *custom = components.URL;
    if (!custom) return nil;

    __block StreamCacheEntry *entry;
    dispatch_sync(_queue, ^{
        entry = self->_entries[uri];
        if (!entry) {
            entry = [[StreamCacheEntry alloc] initWithURL:uri directory:[self directoryForURL:uri]];
            self->_entries[uri] = entry;
        }
        entry.refCount += 1;
        // Validation is per load: the server may have replaced the file since.
        entry.validated = NO;
        entry.writable = YES;
        entry.lastAccess = [NSDate date].timeIntervalSince1970;
    });
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:custom options:options];
    StreamCacheLoader *loader = [[StreamCacheLoader alloc] init];
    loader.entry = entry;
    [asset.resourceLoader setDelegate:loader queue:_queue];
    // AVAssetResourceLoader holds its delegate weakly.
    objc_setAssociatedObject(asset, &kLoaderKey, loader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return asset;
}

- (void)releaseEntry:(StreamCacheEntry *)entry {
    dispatch_async(_queue, ^{
        entry.refCount -= 1;
        if (0 < entry.refCount) return;
        [entry saveMeta];
        [entry closeHandle];
        [self->_entries removeObjectForKey:entry.url];
    });
}

#pragma mark Requests (on _queue)

- (void)startRequest:(AVAssetResourceLoadingRequest *)request entry:(StreamCacheEntry *)entry {
    StreamCacheOp *op = [[StreamCacheOp alloc] init];
    op.request = request;
    op.entry = entry;
    [_ops addObject:op];
    if (request.contentInformationRequest && !entry.validated) {
        [self startProbe:op];
    } else {
        [self beginData:op];
    }
}

/// Asks the server for two bytes before the player sees any cached data.
/// Finding a replaced file here discards it cleanly; finding it mid-playback
/// can only fail the item.
- (void)startProbe:(StreamCacheOp *)op {
    op.probing = YES;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:op.entry.url]];
    [r setValue:@"bytes=0-1" forHTTPHeaderField:@"Range"];
    op.task = [_session dataTaskWithRequest:r];
    [op.task resume];
}

- (void)beginData:(StreamCacheOp *)op {
    AVAssetResourceLoadingContentInformationRequest *info = op.request.contentInformationRequest;
    if (info) {
        info.contentType = op.entry.contentType;
        info.contentLength = op.entry.total;
        info.byteRangeAccessSupported = op.entry.rangesSupported;
    }
    AVAssetResourceLoadingDataRequest *data = op.request.dataRequest;
    if (!data) {
        [self finish:op error:nil];
        return;
    }
    op.offset = data.currentOffset;
    op.end = data.requestsAllDataToEndOfResource ? op.entry.total
                                                 : data.requestedOffset + data.requestedLength;
    [self pump:op];
}

/// Serves the next stored chunk, or fetches the next hole. One chunk per queue
/// turn, so a cancel from the player can get in between.
- (void)pump:(StreamCacheOp *)op {
    if (op.finished) return;
    if (!(op.offset < op.end)) {
        [self finish:op error:nil];
        return;
    }
    StreamCacheEntry *entry = op.entry;
    long long run = MIN([entry cachedRunFrom:op.offset], op.end - op.offset);
    if (0 < run) {
        NSData *data = [entry readFrom:op.offset length:(NSUInteger)MIN(run, (long long)kDeliveryChunk)];
        if (data.length == 0) {
            // The OS purged the file under us: forget the claim and fetch instead.
            // The stream's identity is still valid, so the player's view of it holds.
            [entry forgetBytes];
        } else {
            [op.request.dataRequest respondWithData:data];
            op.offset += data.length;
            dispatch_async(_queue, ^{ [self pump:op]; });
            return;
        }
    }
    long long holeEnd = [entry holeEndFrom:op.offset limit:op.end];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:entry.url]];
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", op.offset, holeEnd - 1] forHTTPHeaderField:@"Range"];
    if (entry.ifRange) [r setValue:entry.ifRange forHTTPHeaderField:@"If-Range"];
    op.task = [_session dataTaskWithRequest:r];
    [op.task resume];
}

- (StreamCacheOp *)opForTask:(NSURLSessionTask *)task {
    for (StreamCacheOp *op in _ops) {
        if (op.task == task) return op;
    }
    return nil;
}

- (void)finish:(StreamCacheOp *)op error:(NSError *)error {
    if (op.finished) return;
    op.finished = YES;
    [op.task cancel];
    op.task = nil;
    [_ops removeObject:op];
    [op.entry saveMeta];
    if (error) {
        [op.request finishLoadingWithError:error];
    } else {
        [op.request finishLoading];
    }
}

- (void)cancelRequest:(AVAssetResourceLoadingRequest *)request {
    for (StreamCacheOp *op in [_ops copy]) {
        if (op.request != request) continue;
        // AVFoundation already considers it over; it must not be finished again.
        op.finished = YES;
        [op.task cancel];
        op.task = nil;
        [_ops removeObject:op];
        [op.entry saveMeta];
    }
}

#pragma mark Response parsing

static NSString *HeaderValue(NSHTTPURLResponse *response, NSString *name) {
    return [response valueForHTTPHeaderField:name];
}

static long long TotalLength(NSHTTPURLResponse *response) {
    NSString *range = HeaderValue(response, @"Content-Range");
    NSRange slash = [range rangeOfString:@"/" options:NSBackwardsSearch];
    if (range && slash.location != NSNotFound) {
        NSString *total = [range substringFromIndex:slash.location + 1];
        if (![total isEqualToString:@"*"]) return total.longLongValue;
    }
    return response.expectedContentLength;
}

/// The strongest identity offered. A weak ETag promises equivalence, not equal bytes.
static NSString *ValidatorOf(NSHTTPURLResponse *response, long long total) {
    NSString *etag = HeaderValue(response, @"ETag");
    if (etag && ![etag hasPrefix:@"W/"]) return [@"etag:" stringByAppendingString:etag];
    NSString *modified = HeaderValue(response, @"Last-Modified");
    if (modified) return [@"modified:" stringByAppendingString:modified];
    return 0 < total ? [NSString stringWithFormat:@"length:%lld", total] : nil;
}

static NSString *IfRangeOf(NSHTTPURLResponse *response) {
    NSString *etag = HeaderValue(response, @"ETag");
    if (etag && ![etag hasPrefix:@"W/"]) return etag;
    return HeaderValue(response, @"Last-Modified");
}

/// AVPlayer needs a UTI. Podcast CDNs often answer octet-stream, so fall back
/// to the file extension, then to MP3 as by far the most common format.
static NSString *ContentTypeOf(NSHTTPURLResponse *response, NSString *url) {
    if (@available(iOS 14.0, macOS 11.0, *)) {
        NSString *mime = response.MIMEType.lowercaseString;
        if ([mime hasPrefix:@"audio/"]) {
            UTType *type = [UTType typeWithMIMEType:mime];
            if (type) return type.identifier;
        }
        NSString *extension = [NSURLComponents componentsWithString:url].path.pathExtension;
        if (extension.length != 0) {
            UTType *type = [UTType typeWithFilenameExtension:extension];
            if ([type conformsToType:UTTypeAudio]) return type.identifier;
        }
    }
    return @"public.mp3";
}

- (void)adoptProbeResponse:(NSHTTPURLResponse *)response entry:(StreamCacheEntry *)entry {
    long long total = TotalLength(response);
    NSString *validator = ValidatorOf(response, total);
    BOOL changed = entry.hasMetadata && (entry.total != total || ![entry.validator isEqualToString:validator]);
    if (changed) [entry reset];
    entry.total = total;
    entry.validator = validator;
    entry.ifRange = IfRangeOf(response);
    entry.contentType = ContentTypeOf(response, entry.url);
    entry.rangesSupported = response.statusCode == 206;
    // Without any identity a later request could not be matched to these bytes.
    entry.writable = validator != nil && 0 < total && entry.writable;
    entry.hasMetadata = YES;
    entry.validated = YES;
    [entry saveMeta];
}

#pragma mark NSURLSessionDataDelegate (on _queue)

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    StreamCacheOp *op = [self opForTask:task];
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (!op || ![http isKindOfClass:[NSHTTPURLResponse class]]) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (op.probing) {
        if (http.statusCode == 200 || http.statusCode == 206) {
            [self adoptProbeResponse:http entry:op.entry];
        }
        // The outcome is read in didComplete; the two probe bytes are not needed.
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    BOOL acceptable = http.statusCode == 206 || (http.statusCode == 200 && op.offset == 0);
    NSString *validator = ValidatorOf(http, TotalLength(http));
    if (!acceptable || (op.entry.validator && validator && ![op.entry.validator isEqualToString:validator])) {
        // If-Range made the server answer with a different file, or it failed.
        // Nothing fetched so far can be spliced with this: start over next load.
        if (http.statusCode == 200) [op.entry reset];
        completionHandler(NSURLSessionResponseCancel);
        [self finish:op error:[NSError errorWithDomain:NSURLErrorDomain
                                                  code:NSURLErrorBadServerResponse
                                              userInfo:@{NSLocalizedDescriptionKey : @"Stream changed on the server"}]];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    StreamCacheOp *op = [self opForTask:task];
    if (!op || op.probing || op.finished) return;
    if ([op.entry writeData:data at:op.offset]) {
        _bytesSinceEvict += data.length;
        if (kEvictInterval <= _bytesSinceEvict) [self evict];
    } else {
        [self evict];
    }
    [op.request.dataRequest respondWithData:data];
    op.offset += data.length;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    StreamCacheOp *op = [self opForTask:task];
    if (!op || op.finished) return;
    op.task = nil;
    if (op.probing) {
        op.probing = NO;
        if (!op.entry.validated) {
            // Offline: a stored entry is still the best available copy.
            if (!op.entry.hasMetadata) {
                [self finish:op error:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
                return;
            }
            op.entry.validated = YES;
        }
        [self beginData:op];
        return;
    }
    if (error) {
        [self finish:op error:error];
        return;
    }
    [self pump:op];
}

#pragma mark Maintenance (on _queue)

- (NSArray<NSDictionary *> *)storedEntries {
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:_root error:nil]) {
        NSString *directory = [_root stringByAppendingPathComponent:name];
        NSString *metaPath = [directory stringByAppendingPathComponent:@"meta.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *url = meta[@"url"];
        StreamCacheEntry *live = url ? _entries[url] : nil;
        long long bytes = 0;
        if (live) {
            bytes = live.storedBytes;
        } else {
            for (NSArray<NSNumber *> *r in meta[@"ranges"]) bytes += r[1].longLongValue - r[0].longLongValue;
        }
        [result addObject:@{
            @"directory" : directory,
            @"url" : url ?: @"",
            @"bytes" : @(bytes),
            @"lastAccess" : meta[@"lastAccess"] ?: @0,
            @"live" : @(live != nil),
        }];
    }
    return result;
}

/// Evicts whole episodes, least recently used first, never one the player holds.
- (void)evict {
    _bytesSinceEvict = 0;
    if (_maxBytes <= 0) return;
    NSArray<NSDictionary *> *all = [[self storedEntries] sortedArrayUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"lastAccess" ascending:YES]
    ]];
    long long total = 0;
    for (NSDictionary *e in all) total += [e[@"bytes"] longLongValue];
    for (NSDictionary *e in all) {
        if (total <= _maxBytes) return;
        if ([e[@"live"] boolValue]) continue;
        [[NSFileManager defaultManager] removeItemAtPath:e[@"directory"] error:nil];
        total -= [e[@"bytes"] longLongValue];
    }
    if (total <= _maxBytes) return;
    // Only streams in use are left and they alone exceed the limit. Keep the
    // limit true by not storing more of them; playback goes on from the network.
    for (StreamCacheEntry *entry in _entries.allValues) entry.writable = NO;
}

- (void)sizeWithCompletion:(void (^)(long long))completion {
    dispatch_async(_queue, ^{
        long long total = 0;
        for (NSDictionary *e in [self storedEntries]) total += [e[@"bytes"] longLongValue];
        completion(total);
    });
}

- (void)urlsWithCompletion:(void (^)(NSArray<NSString *> *))completion {
    dispatch_async(_queue, ^{
        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        for (NSDictionary *e in [self storedEntries]) {
            if ([e[@"url"] length] != 0) [urls addObject:e[@"url"]];
        }
        completion(urls);
    });
}

- (void)clearKeeping:(NSArray<NSString *> *)keep includeInUse:(BOOL)includeInUse completion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        for (NSDictionary *e in [self storedEntries]) {
            if ([keep containsObject:e[@"url"]]) continue;
            StreamCacheEntry *live = self->_entries[e[@"url"]];
            if (live) {
                // A stopped player can still hold its asset; reset keeps the entry consistent.
                if (includeInUse) [live reset];
                continue;
            }
            [[NSFileManager defaultManager] removeItemAtPath:e[@"directory"] error:nil];
        }
        completion();
    });
}

- (void)removeURL:(NSString *)url completion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (!self->_entries[url]) {
            [[NSFileManager defaultManager] removeItemAtPath:[self directoryForURL:url] error:nil];
        }
        completion();
    });
}

@end
