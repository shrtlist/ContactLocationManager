// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

#import "ContactStoreWrapper.h"
@import Contacts;

@interface ContactStoreWrapper ()
@property (nonatomic, strong) CNContactStore *store;
@end
@implementation ContactStoreWrapper

- (instancetype)init {
    return [self initWithStore:[[CNContactStore alloc] init]];
}
- (instancetype)initWithStore:(CNContactStore *)store {
    if (self = [super init]) {
        _store = store;
    }
    return self;
}

- (nullable CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *)changeHistoryFetchResult:(CNChangeHistoryFetchRequest *)request
                                      error:(NSError *__autoreleasing  _Nullable * _Nullable)error {
    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *fetchResult = [self.store enumeratorForChangeHistoryFetchRequest:request error:error];
    return fetchResult;
}

@end

