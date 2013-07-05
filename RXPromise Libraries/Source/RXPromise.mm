//
//  RXPromise.mm
//
//  Copyright 2013 Andreas Grosam
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.


#if (!__has_feature(objc_arc))
#error this file requires arc enabled
#endif

#import "RXPromise.h"
#include <dispatch/dispatch.h>
#include <cassert>
#include <map>
#import "utility/DLog.h"
#include <cstdio>


#if TARGET_OS_IPHONE
// Compiling for iOS
    #if __IPHONE_OS_VERSION_MIN_REQUIRED >= 60000
        // >= iOS 6.0
        #define RX_DISPATCH_RELEASE(__object) do {} while(0)
        #define RX_DISPATCH_RETAIN(__object) do {} while(0)
        #define RX_DISPATCH_BRIDGE_VOID_CAST(__object) (__bridge void*)__object
    #else
        // <= iOS 5.x
        #define RX_DISPATCH_RELEASE(__object) do {dispatch_release(__object);} while(0)
        #define RX_DISPATCH_RETAIN(__object) do { dispatch_retain(__object); } while(0)
        #define RX_DISPATCH_BRIDGE_VOID_CAST(__object) __object
    #endif
#elif TARGET_OS_MAC
    // Compiling for Mac OS X
    #if MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
        // >= Mac OS X 10.8
        #define RX_DISPATCH_RELEASE(__object) do {} while(0)
        #define RX_DISPATCH_RETAIN(__object) do {} while(0)
        #define RX_DISPATCH_BRIDGE_VOID_CAST(__object) (__bridge void*)__object
    #else
        // <= Mac OS X 10.7.x
        #define RX_DISPATCH_RELEASE(__object) do {dispatch_release(__object);} while(0)
        #define RX_DISPATCH_RETAIN(__object) do { dispatch_retain(__object); } while(0)
        #define RX_DISPATCH_BRIDGE_VOID_CAST(__object) __object
    #endif
#endif


/**
 See <http://promises-aplus.github.io/promises-spec/>  for specification.
 */




@interface NSError (RXResolver)
- (void) rxp_resolvePromise:(RXPromise*)promise;
@end

@interface NSObject (RXResolver)
- (void) rxp_resolvePromise:(RXPromise*)promise;
@end

@interface RXPromise (RXResolver)
- (void) rxp_resolvePromise:(RXPromise*)promise;
@end



/** RXPomise_State */
typedef enum RXPomise_StateT {
    Pending     = 0x0,
    Fulfilled   = 0x01,
    Rejected    = 0x02,
    Cancelled   = 0x06
} RXPomise_State;


@interface RXPromise ()
@property (nonatomic) id result;
@end

@implementation RXPromise {
    RXPromise*          _parent;
    dispatch_queue_t    _handler_queue;     // a serial queue, uses target queue: s_sync_queue
    id                  _result;
    RXPomise_State      _state;
}
@synthesize result = _result;
@synthesize parent = _parent;

typedef std::multimap<void const*, __weak RXPromise*> assocs_t;

static dispatch_queue_t s_sync_queue;
static assocs_t  s_assocs;
static dispatch_once_t  onceSharedQueues;

const static char* QueueID = "queue_id";


// Designated Initializer
- (id)initWithParent:(RXPromise*)parent {
    dispatch_once(&onceSharedQueues, ^{
        s_sync_queue = dispatch_queue_create("s_sync_queue", NULL);
        assert(s_sync_queue);
        dispatch_queue_set_specific(s_sync_queue, QueueID, RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue), NULL);
    });
    self = [super init];
    if (self) {
        _parent = parent;
    }
    DLogInfo(@"create: %p", (__bridge void*)self);
    return self;
}

- (id)init {
    return [self initWithParent:nil];
}

- (void) dealloc {
    DLogInfo(@"dealloc: %p", (__bridge void*)self);
    if (_handler_queue) {
        DLogWarn(@"handlers not signaled");
        dispatch_resume(_handler_queue);
        RX_DISPATCH_RELEASE(_handler_queue);
    }
    void const* key = (__bridge void const*)(self);
    dispatch_async(s_sync_queue, ^{
        s_assocs.erase(key);
    });
}

#pragma mark -

- (BOOL) isPending {
    return _state == Pending ? YES : NO;
}

- (BOOL) isFulfilled {
    return _state == Fulfilled ? YES : NO;
}

- (BOOL) isRejected {
    return ((_state & Rejected) != 0) ? YES : NO;
}

- (BOOL) isCancelled {
    return _state == Cancelled ? YES : NO;
}





- (id) synced_result {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    return _result;
}

- (dispatch_queue_t) handlerQueue
{
    if (dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue)) {
        dispatch_queue_t queue = [self synced_handlerQueue];
        RX_DISPATCH_RETAIN(queue);
        return queue;
    }
    else {
        __block dispatch_queue_t queue = nil;
        dispatch_sync(s_sync_queue, ^{
            queue = [self synced_handlerQueue];
            RX_DISPATCH_RETAIN(queue);
        });
        return queue;
    }
}

// Returns the queue where the handlers will be executed.
// Returns the parent queue if the receiver has already been resolved.
-(dispatch_queue_t) synced_handlerQueue {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    if (_state == Pending) {
        if (_handler_queue == nil) {
            char buffer[64];
            snprintf(buffer, sizeof(buffer),"RXPromise_handler_queue-%p", (__bridge void*)self);
            _handler_queue = dispatch_queue_create(buffer, DISPATCH_QUEUE_SERIAL);
            dispatch_set_target_queue(_handler_queue, s_sync_queue);
            dispatch_suspend(_handler_queue);
        }
        assert(_handler_queue);
        return _handler_queue;
    }
    assert(s_sync_queue);
    return s_sync_queue;
}


- (void) resolveWithResult:(id)result {
    dispatch_async(s_sync_queue, ^{
        [self synced_resolveWithResult:result];
    });
}

- (void) fulfillWithValue:(id)value {
    assert(![value isKindOfClass:[NSError class]]);
    dispatch_async(s_sync_queue, ^{
        [self synced_fulfillWithValue:value];
    });
}

- (void) rejectWithReason:(id)reason {
    dispatch_async(s_sync_queue, ^{
        [self synced_rejectWithReason:reason];
    });
}

- (void) cancel {
    [self cancelWithReason:@"cancelled"];
}

- (void) cancelWithReason:(id)reason {
    dispatch_async(s_sync_queue, ^{
        [self synced_cancelWithReason:reason];
    });
}


- (void) synced_resolveWithResult:(id)result {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    if (result == nil) {
        [self synced_fulfillWithValue:nil];
    }
    else {
        [result rxp_resolvePromise:self];
    }
}

- (void) synced_fulfillWithValue:(id)result {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    if (_state != Pending) {
        return;
    }
    _result = result;
    _state = Fulfilled;
    if (_handler_queue) {
        dispatch_resume(_handler_queue);
        RX_DISPATCH_RELEASE(_handler_queue);
        _handler_queue = nil;
    }
}

- (void) synced_rejectWithReason:(id)reason {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    if (_state != Pending) {
        return;
    }
    if (![reason isKindOfClass:[NSError class]]) {
        reason = [[NSError alloc] initWithDomain:@"RXPromise" code:-1000 userInfo:@{NSLocalizedFailureReasonErrorKey: reason}];
    }
    _result = reason;
    _state = Rejected;
    if (_handler_queue) {
        dispatch_resume(_handler_queue);
        RX_DISPATCH_RELEASE(_handler_queue);
        _handler_queue = nil;
    }
}

- (void) synced_cancelWithReason:(id)reason {
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    if (_state == Cancelled) {
        return;
    }
    if (![reason isKindOfClass:[NSError class]]) {
        reason = [[NSError alloc] initWithDomain:@"RXPromise" code:-1 userInfo:@{NSLocalizedFailureReasonErrorKey: reason}];
    }
    if (_state == Pending) {
        DLogDebug(@"cancelled %p.", (__bridge void*)(self));
        _result = reason;
        _state = Cancelled;
        if (_handler_queue) {
            dispatch_resume(_handler_queue);
            RX_DISPATCH_RELEASE(_handler_queue);
            _handler_queue = nil;
        }
    }
    if (_state != Cancelled) {
        // We cancelled the promise at a time as it already was resolved.
        // That means, the _handler_queue is gone and we cannot forward the
        // cancellation event to any child ("returnedPromise") anymore.
        // In order to cancel the possibly already resolved children promises,
        // we need to send cancel to each promise in the children list:
        void const* key = (__bridge void const*)(self);
        auto range = s_assocs.equal_range(key);
        while (range.first != range.second) {
            DLogDebug(@"%p forwarding cancel to %p", key, (__bridge void*)((*(range.first)).second));
            [(*(range.first)).second cancel];
            ++range.first;
        }
        s_assocs.erase(key);
    }
}

// Registers success and failure handlers.
// The receiver will be retained and only released when the receiver will be
// resolved (see "Requirements for an asynchronous result provider").
// Returns a new promise which represents the return values of the handler
// blocks.
- (RXPromise*) registerOnSuccess:(completionHandler_t)onSuccess
                       onFailure:(errorHandler_t)onFailure
                   returnPromise:(BOOL)returnPromise    __attribute((ns_returns_retained))
{
    RXPromise* returnedPromise = returnPromise ? [[RXPromise alloc] initWithParent:self] : nil;
    __weak RXPromise* weakReturnedPromise = returnedPromise;
    __block RXPromise* blockSelf = self;
    assert(s_sync_queue);
    dispatch_queue_t q = self.handlerQueue;
    assert(q);
    //assert(q == s_sync_queue || q == _handler_queue);
    DLogInfo(@"promise %p register handlers %p %p returning promise: %p",
             (__bridge void*)(blockSelf), (__bridge void*)(onSuccess), (__bridge void*)(onFailure), (__bridge void*)(returnedPromise));
    dispatch_async(q, ^{
        // A handler fires:
        @autoreleasepool { // mainly for releasing unused return values from the handlers
            assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
            assert(_state != Pending);
            id result = _result;
            RXPomise_State state = _state;
            id handlerResult;
            if (state == Fulfilled) {
                handlerResult = onSuccess ? onSuccess(result) : result;
            }
            else {
                handlerResult = onFailure ? onFailure(result) : result;
            }
            RXPromise* strongReturnedPromise = weakReturnedPromise;
            if (strongReturnedPromise) {
                assert(handlerResult != strongReturnedPromise); // @"cyclic promise error");
                if (state == Cancelled) {
                    [strongReturnedPromise synced_cancelWithReason:handlerResult];
                }
                else {
                    DLogInfo(@"%p add child %p", (__bridge void*)(blockSelf), (__bridge void*)(strongReturnedPromise));
                    s_assocs.emplace((__bridge void*)(blockSelf), weakReturnedPromise);
                    // There are four cases how the returned promise will be resolved:
                    // 1. handlerResult equals nil              -> fulFilled with nil
                    // 2. handlerResult isKindOfClass RXPromise -> fulFilled with promise
                    // 3. handlerResult isKindOfClass NSError   -> rejected with reason error
                    // 4  handlerResult is any other object     -> fulFilled with value
                    if (handlerResult == nil) {
                        [strongReturnedPromise synced_fulfillWithValue:nil];
                    }
                    else {
                        [handlerResult rxp_resolvePromise:strongReturnedPromise];
                    }
                }
            }
        }
        blockSelf = nil;
    });
    RX_DISPATCH_RELEASE(q);
    return returnedPromise;
}

- (then_block_t) then {
    __block RXPromise* blockSelf = self;
    return ^RXPromise*(completionHandler_t onSucess, errorHandler_t onFailure) __attribute((ns_returns_retained)) {
        RXPromise* p = [blockSelf registerOnSuccess:onSucess onFailure:onFailure returnPromise:YES];
        blockSelf = nil;
        return p;
    };
}


#pragma mark -

- (id) get
{
    assert(dispatch_get_specific(QueueID) != RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue)); // Must not execute on the private sync queue!
    
    __block id result;
    __block dispatch_semaphore_t avail = NULL;
    dispatch_sync(s_sync_queue, ^{
        if (_state != Pending) {
            result = _result;
            return;
        } else {
            avail = dispatch_semaphore_create(0);
            dispatch_async([self synced_handlerQueue], ^{
                dispatch_semaphore_signal(avail);
            });
        }
    });
    if (avail) {
        // result was not yet availbale: queue a handler
        if (dispatch_semaphore_wait(avail, DISPATCH_TIME_FOREVER) == 0) { // wait until handler_queue will be resumed ...
            dispatch_sync(s_sync_queue, ^{  // safely retrieve _result
                result = _result;
            });
        }
        RX_DISPATCH_RELEASE(avail);
    }
    return _result;
}


- (id) get2 {
    assert(dispatch_get_specific(QueueID) != RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue)); // Must not execute on the private sync queue!
    __block id result;
    dispatch_semaphore_t avail = dispatch_semaphore_create(0);
    dispatch_async(self.handlerQueue, ^{
        result = _result;
        dispatch_semaphore_signal(avail);
    });
    dispatch_semaphore_wait(avail, DISPATCH_TIME_FOREVER);
    RX_DISPATCH_RELEASE(avail);
    return result;
}


- (void) wait {
    [self get];
}


- (void) bind:(RXPromise*) other {
    if (dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue)) {
        [self synced_bind:other];
    }
    else {
        dispatch_async(s_sync_queue, ^{
            [self synced_bind:other];
        });
    }
}

// Promise `other` will be retained and released only until after `other` will be
// resolved.
- (void) synced_bind:(RXPromise*) other {
    assert(other != nil);
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    assert(_state == Pending || _state == Cancelled);

    if (_state == Cancelled) {
        [other cancelWithReason:_result];
        return;
    }
    __weak RXPromise* weakSelf = self;
    [other registerOnSuccess:^id(id result) {
        RXPromise* strongSelf = weakSelf;
        [strongSelf synced_fulfillWithValue:result];  // §2.2: if self is fulfilled, fulfill promise with the same value
        return nil;
    } onFailure:^id(NSError *error) {
        RXPromise* strongSelf = weakSelf;
        [strongSelf rejectWithReason:error];          // §2.3: if self is rejected, reject promise with the same value.
        return nil;
    } returnPromise:NO];
    
    __weak RXPromise* weakOther = other;
    [self registerOnSuccess:nil onFailure:^id(NSError *error) {
        RXPromise* strongSelf = weakSelf;
        if (strongSelf) {
            if (strongSelf->_state == Cancelled) {
                RXPromise* strongOther = weakOther;
                [strongOther cancelWithReason:error];
            }
        }
        return error;
    } returnPromise:NO];
}




#pragma mark -


+(RXPromise*) all:(NSArray*)promises
{
    __block int count = (int)[promises count];
    assert(count > 0);
    RXPromise* promise = [[RXPromise alloc] init];
    completionHandler_t onSuccess = ^(id result){
        --count;
        if (count == 0) {
            [promise fulfillWithValue:promises];
        }
        return result;
    };
    errorHandler_t onError = ^(NSError* error) {
        [promise rejectWithReason:error];
        return error;
    };
    dispatch_async(s_sync_queue, ^{
        for (RXPromise* p in promises) {
            p.then(onSuccess, onError);
        }
    });
    
    promise.then(nil, ^id(NSError*error){
        for (RXPromise* p in promises) {
            [p cancelWithReason:error];
        }
        return error;
    });
    
    return promise;
}




#pragma mark -

- (NSString*) description {
    __block NSString* desc;
    dispatch_sync(s_sync_queue, ^{
        desc = [self rxp_descriptionLevel:0];
    });
    return desc;
}

- (NSString*) debugDescription {
    return [self rxp_descriptionLevel:0];
}


- (NSString*) rxp_descriptionLevel:(int)level {
    NSString* indent = [NSString stringWithFormat:@"%*s",4*level+4,""];
    NSMutableString* desc = [[NSMutableString alloc] initWithFormat:@"%@<%@:%p> { State: %@ }",
                             indent,
                             NSStringFromClass([self class]), (__bridge void*)self,
                             ( (_state == Fulfilled)?[NSString stringWithFormat:@"fulfilled with value: %@", _result]:
                              (_state == Rejected)?[NSString stringWithFormat:@"rejected with reason: %@", _result]:
                              (_state == Cancelled)?[NSString stringWithFormat:@"cancelled with reason: %@", _result]
                              :@"pending")
                             ];
    void* key = (__bridge void*)(self);
    auto range = s_assocs.equal_range(key);
    if (range.first != range.second) {
        [desc appendString:[NSString stringWithFormat:@", children: [\n"]];
        while (range.first != range.second) {
            RXPromise* p = (*(range.first)).second;
            [desc appendString:[p rxp_descriptionLevel:level+1]];
            [desc appendString:@"\n"];
            ++range.first;
        }
        [desc appendString:[NSString stringWithFormat:@"%@]", indent]];
    }
    
    return desc;
}

@end


#pragma mark - RXResolver

@implementation RXPromise (RXResolver)
- (void) rxp_resolvePromise:(RXPromise*)promise
{
    assert(dispatch_get_specific(QueueID) == RX_DISPATCH_BRIDGE_VOID_CAST(s_sync_queue));
    [promise synced_bind:self];
}
@end

@implementation NSObject (RXResolver)
- (void) rxp_resolvePromise:(RXPromise*)promise {
    // This is not strict according the spec:
    // If value is an object we require it to be a `thenable` or we must
    // reject the promise with an appropriate error.
    // However this API supports only objects, that is, our value is always
    // an `id` and not a struct or other primitive C type or a C++ class, etc.
    // We also do not support `thenables`.
    // So, we handle values which are not RXPromises and not NSErrors as if
    // they were non-objects and simply fulfill the promise with this value.
    [promise fulfillWithValue:self]; // forward result
}

@end

@implementation NSError (RXResolver)

- (void) rxp_resolvePromise:(RXPromise*)promise {
    [promise rejectWithReason:self];
}

@end

