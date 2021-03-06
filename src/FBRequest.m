/*
 * Copyright 2010 Facebook
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBRequest.h"
///////////////////////////////////////////////////////////////////////////////////////////////////
// global

static NSString* kUserAgent = @"FacebookConnect";
static NSString* kStringBoundary = @"3i2ndDfv2rTHiSisAbouNdArYfORhtTPEefj3q2f";
static const int kGeneralErrorCode = 10000;
static const int kRESTAPIAccessTokenErrorCode = 190;

static const NSTimeInterval kTimeoutInterval = 180.0;

///////////////////////////////////////////////////////////////////////////////////////////////////

@interface FBRequest ()
@property (nonatomic,readwrite) FBRequestState state;
@property (nonatomic,readwrite) BOOL sessionDidExpire;
@end

@implementation FBRequest

@synthesize delegate = _delegate,
            url = _url,
            httpMethod = _httpMethod,
            params = _params,
            connection = _connection,
            responseText = _responseText,
            state = _state,
            sessionDidExpire = _sessionDidExpire,
            error = _error;

//////////////////////////////////////////////////////////////////////////////////////////////////
// class public

+ (FBRequest *)getRequestWithParams:(NSMutableDictionary *) params
                         httpMethod:(NSString *) httpMethod
                           delegate:(id<FBRequestDelegate>) delegate
                         requestURL:(NSString *) url {
    
    FBRequest* request = [[FBRequest alloc] init];
    request.delegate = delegate;
    request.url = url;
    request.httpMethod = httpMethod;
    request.params = params;
    request.connection = nil;
    request.responseText = nil;
    
    return request;
}

#pragma mark - Json Helper functions
///////////////////////////////////////////////////////////////////////////////////////////////////
// Json Helper functions

+ (NSString *)getJsonStringFromObject:(id)jsonObject{
    NSError * error = nil;
    NSData * jsonData = [NSJSONSerialization dataWithJSONObject:jsonObject options:NSJSONWritingPrettyPrinted error:&error];
    if (error!=nil) {
        NSLog(@"JSONSerialization Create Error: %d Description: %@",error.code,error.description);
        return nil;
    }
    NSString * jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return  jsonString;
}

+ (id)getObjectFromJsonData:(NSData *)jsonData{
    NSError * error = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                    options:NSJSONReadingAllowFragments | NSJSONReadingMutableContainers
                                                      error:&error];
    if (error!=nil) {
        NSLog(@"JSONSerialization Decode Error: %d Description: %@",error.code,error.description);
        return nil;
    }
    return jsonObject;
}

+ (id)getObjectFromJsonString:(NSString *)jsonString{
    const char *cstr = [jsonString UTF8String];
    NSData *data = [NSData dataWithBytes:cstr length:jsonString.length];
    return [FBRequest getObjectFromJsonData:data];
}


#pragma mark - private
///////////////////////////////////////////////////////////////////////////////////////////////////
// private

+ (NSString *)serializeURL:(NSString *)baseUrl
                    params:(NSDictionary *)params {
    return [self serializeURL:baseUrl params:params httpMethod:@"GET"];
}

/**
 * Generate get URL
 */
+ (NSString*)serializeURL:(NSString *)baseUrl
                   params:(NSDictionary *)params
               httpMethod:(NSString *)httpMethod {
    
    NSURL* parsedURL = [NSURL URLWithString:baseUrl];
    NSString* queryPrefix = parsedURL.query ? @"&" : @"?";
    
    NSMutableArray* pairs = [NSMutableArray array];
    for (NSString* key in [params keyEnumerator]) {
        if (([[params objectForKey:key] isKindOfClass:[UIImage class]])
            ||([[params objectForKey:key] isKindOfClass:[NSData class]])) {
            if ([httpMethod isEqualToString:@"GET"]) {
                NSLog(@"can not use GET to upload a file");
            }
            continue;
        }
        
        NSString* escaped_value = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
                                                                                      NULL, /* allocator */
                                                                                      (__bridge CFStringRef)[params objectForKey:key],
                                                                                      NULL, /* charactersToLeaveUnescaped */
                                                                                      (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                                                                      kCFStringEncodingUTF8);
        
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, escaped_value]];
    }
    NSString* query = [pairs componentsJoinedByString:@"&"];
    
    return [NSString stringWithFormat:@"%@%@%@", baseUrl, queryPrefix, query];
}

/**
 * Body append for POST method
 */
- (void)utfAppendBody:(NSMutableData *)body data:(NSString *)data {
    [body appendData:[data dataUsingEncoding:NSUTF8StringEncoding]];
}

/**
 * Generate body for POST method
 */
- (NSMutableData *)generatePostBody {
    NSMutableData *body = [NSMutableData data];
    NSString *endLine = [NSString stringWithFormat:@"\r\n--%@\r\n", kStringBoundary];
    NSMutableDictionary *dataDictionary = [NSMutableDictionary dictionary];
    
    [self utfAppendBody:body data:[NSString stringWithFormat:@"--%@\r\n", kStringBoundary]];
    
    for (id key in [_params keyEnumerator]) {
        
        if (([[_params objectForKey:key] isKindOfClass:[UIImage class]])
            ||([[_params objectForKey:key] isKindOfClass:[NSData class]])) {
            
            [dataDictionary setObject:[_params objectForKey:key] forKey:key];
            continue;
            
        }
        
        [self utfAppendBody:body
                       data:[NSString
                             stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n",
                             key]];
        [self utfAppendBody:body data:[_params objectForKey:key]];
        
        [self utfAppendBody:body data:endLine];
    }
    
    if ([dataDictionary count] > 0) {
        for (id key in dataDictionary) {
            NSObject *dataParam = [dataDictionary objectForKey:key];
            if ([dataParam isKindOfClass:[UIImage class]]) {
                NSData* imageData = UIImagePNGRepresentation((UIImage*)dataParam);
                [self utfAppendBody:body
                               data:[NSString stringWithFormat:
                                     @"Content-Disposition: form-data; filename=\"%@\"\r\n", key]];
                [self utfAppendBody:body
                               data:[NSString stringWithString:@"Content-Type: image/png\r\n\r\n"]];
                [body appendData:imageData];
            } else {
                NSAssert([dataParam isKindOfClass:[NSData class]],
                         @"dataParam must be a UIImage or NSData");
                [self utfAppendBody:body
                               data:[NSString stringWithFormat:
                                     @"Content-Disposition: form-data; filename=\"%@\"\r\n", key]];
                [self utfAppendBody:body
                               data:[NSString stringWithString:@"Content-Type: content/unknown\r\n\r\n"]];
                [body appendData:(NSData*)dataParam];
            }
            [self utfAppendBody:body data:endLine];
            
        }
    }
    
    return body;
}

/**
 * Formulate the NSError
 */
- (id)formError:(NSInteger)code userInfo:(NSDictionary *) errorData {
    return [NSError errorWithDomain:@"facebookErrDomain" code:code userInfo:errorData];
    
}

/**
 * parse the response data
 */
- (id)parseJsonResponse:(NSData *)data error:(NSError **)error {
    
    NSString* responseString = [[NSString alloc] initWithData:data
                                                      encoding:NSUTF8StringEncoding];
    if ([responseString isEqualToString:@"true"]) {
        return [NSDictionary dictionaryWithObject:@"true" forKey:@"result"];
    } else if ([responseString isEqualToString:@"false"]) {
        if (error != nil) {
            *error = [self formError:kGeneralErrorCode
                            userInfo:[NSDictionary
                                      dictionaryWithObject:@"This operation can not be completed"
                                      forKey:@"error_msg"]];
        }
        return nil;
    }
    
    
    id result = [FBRequest getObjectFromJsonString:responseString];

    if (result == nil) {
        return responseString;
    }

    if ([result isKindOfClass:[NSDictionary class]]) {
        if ([result objectForKey:@"error"] != nil) {
            if (error != nil) {
                *error = [self formError:kGeneralErrorCode
                                userInfo:result];
            }
            return nil;
        }
        
        if ([result objectForKey:@"error_code"] != nil) {
            if (error != nil) {
                *error = [self formError:[[result objectForKey:@"error_code"] intValue] userInfo:result];
            }
            return nil;
        }
        
        if ([result objectForKey:@"error_msg"] != nil) {
            if (error != nil) {
                *error = [self formError:kGeneralErrorCode userInfo:result];
            }
        }
        
        if ([result objectForKey:@"error_reason"] != nil) {
            if (error != nil) {
                *error = [self formError:kGeneralErrorCode userInfo:result];
            }
        }
    }
    
    return result;
    
}

/*
 * private helper function: call the delegate function when the request
 *                          fails with error
 */
- (void)failWithError:(NSError *)error {
    if ([error code] == kRESTAPIAccessTokenErrorCode) {
        self.sessionDidExpire = YES;
    }
    if ([_delegate respondsToSelector:@selector(request:didFailWithError:)]) {
        [_delegate request:self didFailWithError:error];
    }
}

/*
 * private helper function: handle the response data
 */
- (void)handleResponseData:(NSData *)data {
    if ([_delegate respondsToSelector:
         @selector(request:didLoadRawResponse:)]) {
        [_delegate request:self didLoadRawResponse:data];
    }
    
    NSError* error = nil;
    id result = [self parseJsonResponse:data error:&error];
    self.error = error;  
    
    if ([_delegate respondsToSelector:@selector(request:didLoad:)] ||
        [_delegate respondsToSelector:
         @selector(request:didFailWithError:)]) {
            
            if (error) {
                [self failWithError:error];
            } else if ([_delegate respondsToSelector:
                        @selector(request:didLoad:)]) {
                [_delegate request:self didLoad:result];
            }
            
        }
    
}



//////////////////////////////////////////////////////////////////////////////////////////////////
// public

/**
 * @return boolean - whether this request is processing
 */
- (BOOL)loading {
    return !!_connection;
}

/**
 * make the Facebook request
 */
- (void)connect {
    
    if ([_delegate respondsToSelector:@selector(requestLoading:)]) {
        [_delegate requestLoading:self];
    }
    
    NSString* url = [[self class] serializeURL:_url params:_params httpMethod:_httpMethod];
    NSMutableURLRequest* request =
    [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                        timeoutInterval:kTimeoutInterval];
    [request setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];


    [request setHTTPMethod:self.httpMethod];
    if ([self.httpMethod isEqualToString: @"POST"]) {
        NSString* contentType = [NSString
                             stringWithFormat:@"multipart/form-data; boundary=%@", kStringBoundary];
        [request setValue:contentType forHTTPHeaderField:@"Content-Type"];

        [request setHTTPBody:[self generatePostBody]];
    }

    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    self.state = kFBRequestStateLoading;
    self.sessionDidExpire = NO;
}

/**
 * Free internal structure
 */
- (void)dealloc {
    [_connection cancel];
}

//////////////////////////////////////////////////////////////////////////////////////////////////
// NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    _responseText = [[NSMutableData alloc] init];
    
    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
    if ([_delegate respondsToSelector:
         @selector(request:didReceiveResponse:)]) {
        [_delegate request:self didReceiveResponse:httpResponse];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_responseText appendData:data];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse*)cachedResponse {
    return nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self handleResponseData:_responseText];

    self.responseText = nil;
    self.connection = nil;
    self.state = kFBRequestStateComplete;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self failWithError:error];

    self.responseText = nil;
    self.connection = nil;
    self.state = kFBRequestStateComplete;
}

@end
