//
//  LXNetworkingManager.m
//  LXNetworking
//
//  Created by liuxin on 2019/1/7.
//  Copyright © 2019年 liuxin. All rights reserved.
//

#import "LXNetworkingManager.h"
#import "LXNetworkingConfig.h"
#import "LXError.h"
#import "LXNetworkCache.h"

NSString * const LXDNetworkCacheSharedName = @"LXDNetworkCacheSharedName";
NSString * const LXDNetworkCacheKeys = @"LXDNetworkCacheKeys";

@interface LXNetworkingManager ()

/**
 是AFURLSessionManager的子类，为HTTP的一些请求提供了便利方法，当提供baseURL时，请求只需要给出请求的路径即可
 */
@property (nonatomic, strong) AFHTTPSessionManager *requestManager;

/**
 将LXRequestMethod（NSInteger）类型转换成对应的方法名（NSString）
 */
@property (nonatomic, strong) NSDictionary *methodMap;

/**
 这个字典是为了实现 取消某一个urlString的本地网络缓存数据而设计，字典结构如下
 key:urlString
 value: @[cacheKey1, cacheKey2]
 当调用clearRequestCache:identifier:方法时，根据key找到对应的value，
 然后进行指定缓存、或者根据urlString批量删除
 */
@property (nonatomic, strong) NSMutableDictionary <NSString *, NSMutableSet <NSString *>*>*cacheKeys;

@end



@implementation LXNetworkingManager


+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
            NSLog(@"Reachability: %@", AFStringFromNetworkReachabilityStatus(status));
            self.networkStatus = status;
        }];
        [[AFNetworkReachabilityManager sharedManager] startMonitoring];
        
        [[AFNetworkActivityLogger sharedLogger] setLevel:AFLoggerLevelInfo];
        [[AFNetworkActivityLogger sharedLogger] startLogging];
        
        self.configuration = [[LXNetworkingConfig alloc] init];
        
        _methodMap = @{
                       @"0" : @"GET",
                       @"1" : @"HEAD",
                       @"2" : @"POST",
                       @"3" : @"PUT",
                       @"4" : @"PATCH",
                       @"5" : @"DELETE",
                       };
        if (!_cacheKeys) {
            _cacheKeys = [NSMutableDictionary dictionary];
        }
    }
    return self;
}

#pragma mark - 实例化
- (AFHTTPSessionManager *)requestManager {
    if (!_requestManager) {
        _requestManager = [AFHTTPSessionManager manager] ;
        AFSecurityPolicy *securityPolicy = [AFSecurityPolicy defaultPolicy];
        securityPolicy.allowInvalidCertificates = YES;
        securityPolicy.validatesDomainName = NO;
        _requestManager.securityPolicy = securityPolicy;
    }
    return _requestManager;
}

#pragma mark - 公开方法
/**
 设置网络请求的log等级
 
 @param loggerLevel log等级，当网络请求失败时，无论是哪种等级都会打印error信息，当网络成功时，
 AFLoggerLevelInfo：打印请求的code码、请求的url和本次请求耗时；
 AFLoggerLevelDebug/AFLoggerLevelWarn/AFLoggerLevelError：打印请求的code码、请求的url、本次请求耗时、header信息及返回数据；
 */
- (void)setLoggerLevel:(AFHTTPRequestLoggerLevel)loggerLevel {
    [[AFNetworkActivityLogger sharedLogger] setLevel:loggerLevel];
}

#pragma mark - 接口管理
/**
 提供给上层请求
 
 @param method 请求的方法，可以在configuration选择是否缓存数据
 @param URLString 请求的URL地址，不包含baseUrl
 @param parameters 请求的参数
 @param configurationHandler 将默认的配置给到外面，外面可能需要特殊处理，可以修改baseUrl等信息
 @param cache 如果有的话返回缓存数据（⚠️⚠️缓存的数据是服务器返回的数据，而不是经过configuration处理后的数据）
 @param success 请求成功
 @param failure 请求失败
 @return 返回该请求的任务管理者，用于取消该次请求(⚠️⚠️，当返回值为nil时，表明并没有进行网络请求，那就是取缓存数据)
 */
- (NSURLSessionDataTask *_Nullable)requestMethod:(LXRequestMethod)method
                                       URLString:(NSString *_Nullable)URLString
                                      parameters:(NSDictionary *_Nullable)parameters
                            configurationHandler:(void (^_Nullable)(LXNetworkingConfig * _Nullable configuration))configurationHandler
                                           cache:(LXRequestManagerCache _Nullable )cache
                                         success:(LXRequestManagerSuccess _Nullable )success
                                         failure:(LXRequestManagerFailure _Nullable )failure {
    LXNetworkingConfig *configuration = [self disposeConfiguration:configurationHandler];
    if (!URLString) {
        URLString = @"";
    }
    NSString *requestUrl = [[NSURL URLWithString:URLString relativeToURL:[NSURL URLWithString:configuration.baseURL]] absoluteString];
    parameters = [self disposeRequestParameters:parameters];
    NSLog(@"请求参数 ---> %@",parameters);
    //获取缓存数据
//    NSString *cacheKey = [requestUrl stringByAppendingString:[self serializeParams:parameters]];
    id (^ fetchCacheRespose)(void) = ^id (void) {
        
       id resposeObject = [LXNetworkCache httpCacheForURL:requestUrl parameters:parameters cacheValidTime:configuration.resultCacheDuration];
        if (resposeObject) {
            return resposeObject;
        }
        return nil;
    };
    
    if (configuration.requestCachePolicy == LXRequestReturnCacheDontLoad ||
        configuration.requestCachePolicy == LXRequestReturnCacheAndLoadToCache ||
        configuration.requestCachePolicy == LXRequestReturnCacheOrLoadToCache) {
        id resposeObject = fetchCacheRespose();
        cache(resposeObject);
        
        if (configuration.requestCachePolicy == LXRequestReturnCacheOrLoadToCache && resposeObject) {
            return nil;
        }
        
        if (configuration.requestCachePolicy == LXRequestReturnCacheDontLoad) {
            return nil;
        }
    }
    
    //存数据
    void (^ saveCacheRespose)(id responseObject) = ^(id responseObject) {
        if (configuration.resultCacheDuration > 0) {
            NSLog(@"存数据-- ，requestUrl = [%@] , %zd , %zd",requestUrl ,configuration.resultCacheDuration , configuration.requestCachePolicy);
            [LXNetworkCache setHttpCache:responseObject URL:requestUrl parameters:parameters];
        }
    };
    
        //接口请求
        if (method > self.methodMap.count - 1) {
            method = self.methodMap.count - 1;
        }
        NSString *methodKey = [NSString stringWithFormat:@"%d", (int)method];
        NSMutableURLRequest *request = [self.requestManager.requestSerializer requestWithMethod:self.methodMap[methodKey]
                                                                               URLString:requestUrl
                                                                              parameters:parameters
                                                                                   error:nil];
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        __weak typeof(self) weak_self = self;
        __block NSURLSessionDataTask *dataTask = [self.requestManager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
            
            __strong typeof(self) strong_self = weak_self;
            if (error) {
                LXError *LXError;
                if (strong_self.networkStatus == AFNetworkReachabilityStatusNotReachable) {
                    LXError = [configuration.LXError lxErrorNetNotReachable];
                }
                else {
                    LXError = [configuration.LXError lxErrorHttpError:error];
                }
                if (configuration.requestCachePolicy == LXRequestReturnLoadToCache) {
                    id resposeObject = fetchCacheRespose();
                    cache(resposeObject);
                }
                failure(dataTask, LXError);
            }
            else {
                if (configuration.requestCachePolicy != LXRequestReturnLoadDontCache) {
                    saveCacheRespose(responseObject);
                }
                if (configuration.resposeHandle) {
                    responseObject = configuration.resposeHandle(dataTask, responseObject);
                }
                success(dataTask, responseObject);
            }
            
        }];
        
        [dataTask resume];
        return dataTask;
        
    
    
}


/**
 上传资源方法
 
 @param URLString URLString 请求的URL地址，不包含baseUrl
 @param parameters 请求参数
 @param block 将要上传的资源回调
 @param configurationHandler 将默认的配置给到外面，外面可能需要特殊处理，可以修改baseUrl等信息
 @param progress 上传资源进度
 @param success 请求成功
 @param failure 请求失败
 @return 返回该请求的任务管理者，用于取消该次请求(⚠️⚠️，当返回值为nil时，表明并没有进行网络请求，可能是取缓存数据)
 */
- (NSURLSessionTask *_Nullable)uploadWithURLString:(NSString *_Nullable)URLString
                                        parameters:(NSDictionary *_Nullable)parameters
                         constructingBodyWithBlock:(void (^_Nullable)(id <AFMultipartFormData> _Nullable formData))block
                              configurationHandler:(void (^_Nullable)(LXNetworkingConfig * _Nullable configuration))configurationHandler
                                          progress:(LXRequestManagerProgress _Nullable)progress
                                           success:(LXRequestManagerSuccess _Nullable )success
                                           failure:(LXRequestManagerFailure _Nullable )failure {
    LXNetworkingConfig *configuration = [self disposeConfiguration:configurationHandler];
    parameters = [self disposeRequestParameters:parameters];
    NSString *requestUrl = [[NSURL URLWithString:URLString relativeToURL:[NSURL URLWithString:configuration.baseURL]] absoluteString];
    __weak typeof(self) weak_self = self;
    NSURLSessionDataTask *dataTask = [self.requestManager POST:requestUrl
                                                    parameters:parameters
                                     constructingBodyWithBlock:^(id<AFMultipartFormData>  _Nonnull formData) {
                                         block(formData);
                                     } progress:^(NSProgress * _Nonnull uploadProgress) {
                                         progress(uploadProgress);
                                     } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                                         success(task, responseObject);
                                     } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                                         __strong typeof(self) strong_self = weak_self;
                                         LXError *LXError;
                                         if (strong_self.networkStatus == AFNetworkReachabilityStatusNotReachable) {
                                             LXError = [configuration.LXError lxErrorNetNotReachable];
                                         }
                                         else {
                                             LXError = [configuration.LXError lxErrorHttpError:error];
                                         }
                                         failure(task, LXError);
                                     }];
    [dataTask resume];
    return dataTask;
}

/**
 下载资源方法
 
 @param URLString URLString 请求的URL地址，不包含baseUrl
 @param configurationHandler 将默认的配置给到外面，外面可能需要特殊处理，可以修改baseUrl等信息
 @param progress 上传资源进度
 @param success 请求成功
 @param failure 请求失败
 @return 返回该请求的任务管理者，用于取消该次请求
 */
- (NSURLSessionTask *_Nullable)downloadWithURLString:(NSString *_Nullable)URLString
                                configurationHandler:(void (^_Nullable)(LXNetworkingConfig * _Nullable configuration))configurationHandler
                                            progress:(LXRequestManagerProgress _Nullable)progress
                                             success:(LXRequestManagerSuccess _Nullable )success
                                             failure:(LXRequestManagerFailure _Nullable )failure {
    LXNetworkingConfig *configuration = [self disposeConfiguration:configurationHandler];
    NSString *requestUrl = [[NSURL URLWithString:URLString relativeToURL:[NSURL URLWithString:configuration.baseURL]] absoluteString];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:requestUrl]];
    __weak typeof(self) weak_self = self;
    __block NSURLSessionTask *dataTask =
    [self.requestManager downloadTaskWithRequest:request
                                        progress:^(NSProgress * _Nonnull downloadProgress) {
                                            progress(downloadProgress);
                                        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
                                            NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
                                            return [documentsDirectoryURL URLByAppendingPathComponent:[response suggestedFilename]];
                                        } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
                                            __strong typeof(self) strong_self = weak_self;
                                            if (error) {
                                                LXError *LXError;
                                                if (strong_self.networkStatus == AFNetworkReachabilityStatusNotReachable) {
                                                    LXError = [configuration.LXError lxErrorNetNotReachable];
                                                }
                                                else {
                                                    LXError = [configuration.LXError lxErrorHttpError:error];
                                                }
                                                failure(dataTask, LXError);
                                            }
                                            else {
                                                if (self.configuration.resposeHandle) {
                                                    filePath = self.configuration.resposeHandle(dataTask, filePath);
                                                }
                                                success(dataTask, filePath);
                                            }
                                        }];
    [dataTask resume];
    return dataTask;
}

- (void)cancelAllRequest {
    [self.requestManager invalidateSessionCancelingTasks:YES];
}

#pragma mark - 内部方法
- (NSDictionary *)disposeRequestParameters:(NSDictionary *)parameters {
    NSMutableDictionary *bodys = [NSMutableDictionary dictionaryWithDictionary:parameters];
    if (self.configuration.builtinBodys.count > 0) {
        for (NSString *key in self.configuration.builtinBodys) {
            [bodys setObject:self.configuration.builtinBodys[key] forKey:key];
        }
    }
    return bodys;
}

- (LXNetworkingConfig *)disposeConfiguration:(void (^_Nullable)(LXNetworkingConfig * _Nullable configuration))configurationHandler {
    //configuration配置
    LXNetworkingConfig *configuration = [self.configuration copy];
    if (configurationHandler) {
        configurationHandler(configuration);
    }
    self.requestManager.requestSerializer = configuration.requestSerializer;
    self.requestManager.responseSerializer = configuration.responseSerializer;
    if (configuration.builtinHeaders.count > 0) {
        for (NSString *key in configuration.builtinHeaders) {
            [self.requestManager.requestSerializer setValue:configuration.builtinHeaders[key] forHTTPHeaderField:key];
        }
    }
    
    [self.requestManager.requestSerializer willChangeValueForKey:@"timeoutInterval"];
    if (configuration.timeoutInterval > 0) {
        self.requestManager.requestSerializer.timeoutInterval = configuration.timeoutInterval;
    }
    else {
        self.requestManager.requestSerializer.timeoutInterval = LXRequestTimeoutInterval;
    }
    [self.requestManager.requestSerializer didChangeValueForKey:@"timeoutInterval"];
    return configuration;
}


-(NSString *)serializeParams:(NSDictionary *)params {
    NSMutableArray *parts = [NSMutableArray array];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id<NSObject> obj, BOOL *stop) {
        NSString *part = [NSString stringWithFormat: @"%@=%@", key, obj];
        [parts addObject: part];
    }];
    if (parts.count > 0) {
        NSString *queryString = [parts componentsJoinedByString:@"&"];
        return queryString ? [NSString stringWithFormat:@"?%@", queryString] : @"";
    }
    return @"";
}


@end
