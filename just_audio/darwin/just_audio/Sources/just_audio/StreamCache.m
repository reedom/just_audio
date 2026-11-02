#import "./include/just_audio/StreamCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

// AVFoundation only consults the resource loader for schemes it cannot load.
static NSString *const kSchemePrefix = @"justaudiocache-";
static const NSUInteger kDeliveryChunk = 256 * 1024;
static const long long kEvictInterval = 4 * 1024 * 1024;
static const long long kMetaSaveInterval = 1024 * 1024;
// Bounds what is handed to AVFoundation, which has no backpressure of its own,
// while staying far above any audio bitrate.
static const int64_t kDeliveryIntervalNs = 10 * NSEC_PER_MSEC;
// A failed probe of a stored entry falls back to that entry, so waiting long
// would only delay playback that is possible right now.
static const NSTimeInterval kStoredProbeTimeout = 3;
static const NSInteger kMaxRetries = 4;
static const NSTimeInterval kResponseTimeTolerance = 5;
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
/// No longer backed by disk. Whoever still holds it keeps streaming.
@property(nonatomic) BOOL discarded;
/// Advances when the stored file is replaced, so a fetch started before that
/// cannot store its bytes in the new file.
@property(nonatomic) NSUInteger generation;
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
    if (!_writable || _discarded) return NO;
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
    if (!_hasMetadata || _discarded) return;
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
    _generation += 1;
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

/// Keeps what the player was already told about the stream, which it still
/// relies on, and drops only the disk side: every read falls through to the
/// network and nothing can recreate the directory.
- (void)discard {
    _discarded = YES;
    _writable = NO;
    _ifRange = nil;
    [_ranges removeAllObjects];
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
@property(nonatomic) long long taskStartOffset;
/// Bytes at the head of the response before op.offset, from a server that
/// ignored the requested range.
@property(nonatomic) long long skip;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger retries;
@property(nonatomic) BOOL dataStarted;
/// The probe's response is a definite refusal, not a network failure.
@property(nonatomic) BOOL refused;
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
    NSMutableSet<NSString *> *_uncacheable;
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
    _uncacheable = [NSMutableSet set];
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

/// NSURLSession lacks the media exemption AVPlayer gets from
/// NSAllowsArbitraryLoadsForMedia, so an http stream that plays today could not
/// be fetched here.
static BOOL AllowsCleartextFetch(void) {
    NSDictionary *ats = NSBundle.mainBundle.infoDictionary[@"NSAppTransportSecurity"];
    return [ats[@"NSAllowsArbitraryLoads"] boolValue];
}

- (AVURLAsset *)assetForURI:(NSString *)uri options:(NSDictionary *)options {
    __block long long maxBytes;
    __block BOOL uncacheable;
    dispatch_sync(_queue, ^{
        maxBytes = self->_maxBytes;
        uncacheable = [self->_uncacheable containsObject:uri];
    });
    if (maxBytes <= 0 || uncacheable) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:uri];
    NSString *scheme = components.scheme.lowercaseString;
    BOOL cleartext = [scheme isEqualToString:@"http"];
    if (![scheme isEqualToString:@"https"] && !(cleartext && AllowsCleartextFetch())) return nil;
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
        // Nothing is left to deliver to, whatever AVFoundation chose to cancel.
        for (StreamCacheOp *op in [self->_ops copy]) {
            if (op.entry == entry) [self abandon:op];
        }
        [entry saveMeta];
        [entry closeHandle];
        entry.discarded = YES;
        [self detach:entry];
    });
}

- (void)detach:(StreamCacheEntry *)entry {
    if (_entries[entry.url] == entry) [_entries removeObjectForKey:entry.url];
}

/// The server gives no stable file to store: what is playing keeps streaming,
/// and later loads hand AVPlayer the URL directly, as if this cache did not exist.
- (void)stopCaching:(StreamCacheEntry *)entry {
    [_uncacheable addObject:entry.url];
    [entry discard];
    [self detach:entry];
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
    if (op.entry.hasMetadata) r.timeoutInterval = kStoredProbeTimeout;
    op.task = [_session dataTaskWithRequest:r];
    [op.task resume];
}

- (void)beginData:(StreamCacheOp *)op {
    op.dataStarted = YES;
    op.generation = op.entry.generation;
    long long total = op.entry.total;
    AVAssetResourceLoadingContentInformationRequest *info = op.request.contentInformationRequest;
    if (info) {
        info.contentType = op.entry.contentType;
        if (0 < total) info.contentLength = total;
        info.byteRangeAccessSupported = op.entry.rangesSupported;
    }
    AVAssetResourceLoadingDataRequest *data = op.request.dataRequest;
    if (!data) {
        [self finish:op error:nil];
        return;
    }
    op.offset = data.currentOffset;
    op.end = data.requestsAllDataToEndOfResource ? LLONG_MAX : data.requestedOffset + data.requestedLength;
    // Without a known length, the end of the response is the end of the stream.
    if (0 < total) op.end = MIN(op.end, total);
    [self pump:op];
}

/// Serves the next stored chunk, or fetches the next hole. One chunk per queue
/// turn, so a cancel from the player can get in between.
- (void)pump:(StreamCacheOp *)op {
    if (op.finished) return;
    if (op.request.isCancelled) {
        [self abandon:op];
        return;
    }
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kDeliveryIntervalNs), _queue, ^{ [self pump:op]; });
            return;
        }
    }
    long long holeEnd = [entry holeEndFrom:op.offset limit:op.end];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:entry.url]];
    NSString *range = holeEnd == LLONG_MAX ? [NSString stringWithFormat:@"bytes=%lld-", op.offset]
                                           : [NSString stringWithFormat:@"bytes=%lld-%lld", op.offset, holeEnd - 1];
    [r setValue:range forHTTPHeaderField:@"Range"];
    // A server without ranges answers 200 anyway, which would read as a changed file.
    if (entry.ifRange && entry.rangesSupported) [r setValue:entry.ifRange forHTTPHeaderField:@"If-Range"];
    op.taskStartOffset = op.offset;
    op.skip = 0;
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

/// Ends an operation AVFoundation already considers over: finishing it again
/// is not allowed.
- (void)abandon:(StreamCacheOp *)op {
    op.finished = YES;
    [op.task cancel];
    op.task = nil;
    [_ops removeObject:op];
    [op.entry saveMeta];
}

- (void)cancelRequest:(AVAssetResourceLoadingRequest *)request {
    for (StreamCacheOp *op in [_ops copy]) {
        if (op.request == request) [self abandon:op];
    }
}

/// AVPlayer rides out a network drop when it loads a URL itself. Resuming from
/// op.offset gives the same behavior; the bytes already delivered stay valid.
- (void)retry:(StreamCacheOp *)op error:(NSError *)error {
    if (kMaxRetries <= op.retries) {
        [self finish:op error:error];
        return;
    }
    op.retries += 1;
    int64_t delay = (int64_t)(1LL << (op.retries - 1)) * NSEC_PER_SEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), _queue, ^{
        if (op.finished) return;
        if (op.dataStarted) {
            [self pump:op];
        } else {
            [self startProbe:op];
        }
    });
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

/// Some ad-serving CDNs (Triton) send the time of the response as Last-Modified,
/// so it differs on every request for the very same bytes.
static NSString *StableLastModified(NSHTTPURLResponse *response) {
    NSString *modified = HeaderValue(response, @"Last-Modified");
    NSString *date = HeaderValue(response, @"Date");
    if (!modified || !date) return modified;
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    format.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSDate *modifiedAt = [format dateFromString:modified];
    NSDate *respondedAt = [format dateFromString:date];
    if (!modifiedAt || !respondedAt) return modified;
    return [respondedAt timeIntervalSinceDate:modifiedAt] < kResponseTimeTolerance ? nil : modified;
}

/// The strongest identity offered. A weak ETag promises equivalence, not equal bytes.
static NSString *ValidatorOf(NSHTTPURLResponse *response, long long total) {
    NSString *etag = HeaderValue(response, @"ETag");
    if (etag && ![etag hasPrefix:@"W/"]) return [@"etag:" stringByAppendingString:etag];
    NSString *modified = StableLastModified(response);
    if (modified) return [@"modified:" stringByAppendingString:modified];
    return 0 < total ? [NSString stringWithFormat:@"length:%lld", total] : nil;
}

static NSError *BadResponse(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
}

/// A captive portal's page says nothing about the stream behind it.
static BOOL IsNotAudio(NSHTTPURLResponse *response) {
    return [response.MIMEType.lowercaseString hasPrefix:@"text/"];
}

static BOOL IsTransientStatus(NSInteger status) {
    return 500 <= status && status < 600;
}

/// Where the response body starts in the file. A 200 is the whole file.
static long long BodyStart(NSHTTPURLResponse *response) {
    if (response.statusCode != 206) return 0;
    NSString *range = HeaderValue(response, @"Content-Range");
    NSScanner *scanner = [NSScanner scannerWithString:range ?: @""];
    long long start = 0;
    return [scanner scanString:@"bytes" intoString:nil] && [scanner scanLongLong:&start] ? start : -1;
}

static NSString *IfRangeOf(NSHTTPURLResponse *response) {
    NSString *etag = HeaderValue(response, @"ETag");
    if (etag && ![etag hasPrefix:@"W/"]) return etag;
    // If-Range with a response time would make the server answer 200 every time.
    return StableLastModified(response);
}

/// AVPlayer needs a UTI. Podcast CDNs often answer octet-stream, so fall back
/// to the file extension, then to MP3 as by far the most common format.
static NSString *ContentTypeOf(NSHTTPURLResponse *response, NSString *url) {
    if (@available(iOS 14.0, macOS 11.0, *)) {
        NSString *mime = response.MIMEType.lowercaseString;
        if ([mime hasPrefix:@"audio/"]) {
            UTType *type = [UTType typeWithMIMEType:mime];
            // An unknown MIME type yields a made-up dyn.* identifier AVPlayer rejects.
            if (type.isDeclared) return type.identifier;
        }
        NSString *extension = [NSURLComponents componentsWithString:url].path.pathExtension;
        if (extension.length != 0) {
            UTType *type = [UTType typeWithFilenameExtension:extension];
            // .mp4 is declared as a movie even when it holds only audio.
            if (type.isDeclared && [type conformsToType:UTTypeAudiovisualContent]) return type.identifier;
        }
    }
    return @"public.mp3";
}

- (void)adoptProbeResponse:(NSHTTPURLResponse *)response entry:(StreamCacheEntry *)entry {
    long long total = TotalLength(response);
    NSString *validator = ValidatorOf(response, total);
    BOOL changed = entry.hasMetadata && (entry.total != total || ![entry.validator isEqualToString:validator]);
    // Two answers within one load: this server has no stable identity.
    if (changed && entry.validated) {
        [self stopCaching:entry];
        return;
    }
    if (changed) [entry reset];
    entry.total = total;
    entry.validator = validator;
    entry.ifRange = IfRangeOf(response);
    entry.contentType = ContentTypeOf(response, entry.url);
    entry.rangesSupported = response.statusCode == 206;
    entry.hasMetadata = YES;
    entry.validated = YES;
    // Without any identity a later request could not be matched to these bytes.
    if (!validator || total <= 0) {
        [self stopCaching:entry];
        return;
    }
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
    NSInteger status = http.statusCode;
    BOOL success = status == 200 || status == 206;
    if (op.probing) {
        if (success && !IsNotAudio(http)) {
            [self adoptProbeResponse:http entry:op.entry];
        }
        op.refused = !IsTransientStatus(status) && !success;
        // The outcome is read in didComplete; the two probe bytes are not needed.
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (!success || IsNotAudio(http)) {
        op.task = nil;
        completionHandler(NSURLSessionResponseCancel);
        if (success || IsTransientStatus(status)) {
            [self retry:op error:BadResponse()];
        } else {
            [self finish:op error:BadResponse()];
        }
        return;
    }
    StreamCacheEntry *entry = op.entry;
    BOOL sentIfRange = [task.originalRequest valueForHTTPHeaderField:@"If-Range"] != nil;
    if (status == 200 && op.offset != 0 && sentIfRange) {
        // If-Range says the file changed. Ask again for only the range needed.
        [self stopCaching:entry];
        op.task = nil;
        completionHandler(NSURLSessionResponseCancel);
        [self pump:op];
        return;
    }
    NSString *validator = ValidatorOf(http, TotalLength(http));
    if (!entry.discarded && entry.validator && validator && ![entry.validator isEqualToString:validator]) {
        // Mid-playback there is nothing better to serve. Direct playback would
        // receive these same bytes, so only the storing has to stop.
        [self stopCaching:entry];
    }
    long long start = BodyStart(http);
    if (start < 0 || op.offset < start) {
        op.task = nil;
        completionHandler(NSURLSessionResponseCancel);
        [self retry:op error:BadResponse()];
        return;
    }
    op.skip = op.offset - start;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    StreamCacheOp *op = [self opForTask:task];
    if (!op || op.probing || op.finished) return;
    NSData *body = data;
    if (0 < op.skip) {
        if ((long long)body.length <= op.skip) {
            op.skip -= body.length;
            return;
        }
        body = [body subdataWithRange:NSMakeRange((NSUInteger)op.skip, body.length - (NSUInteger)op.skip)];
        op.skip = 0;
    }
    long long wanted = op.end - op.offset;
    if (wanted < (long long)body.length) body = [body subdataWithRange:NSMakeRange(0, (NSUInteger)wanted)];
    StreamCacheEntry *entry = op.entry;
    BOOL current = op.generation == entry.generation;
    BOOL wasStoring = current && entry.writable && !entry.discarded;
    if (wasStoring) {
        if ([entry writeData:body at:op.offset]) {
            _bytesSinceEvict += body.length;
            if (kEvictInterval <= _bytesSinceEvict) [self evict];
        } else {
            // Once per refusal: the disk is full, and a failed write will not recover by retrying each chunk.
            [self evict];
        }
    }
    [op.request.dataRequest respondWithData:body];
    op.offset += body.length;
    op.retries = 0;
    if (!(op.offset < op.end)) [self finish:op error:nil];
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
                if (op.refused) {
                    [self finish:op error:BadResponse()];
                } else {
                    [self retry:op error:error ?: BadResponse()];
                }
                return;
            }
            op.entry.validated = YES;
        }
        [self beginData:op];
        return;
    }
    if (error) {
        [self retry:op error:error];
        return;
    }
    if (op.end == LLONG_MAX) {
        [self finish:op error:nil];
        return;
    }
    // An empty answer would otherwise be asked for again without end.
    if (op.offset == op.taskStartOffset) {
        [self retry:op error:BadResponse()];
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
                // A stopped player can still hold its asset, and only a new load
                // should start storing again.
                if (includeInUse) {
                    [live discard];
                    [self detach:live];
                }
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
