// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

// ContactStoreWrapper.h
#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(macos(10.15), ios(13.0))
@interface ContactStoreWrapper : NSObject
- (instancetype)initWithStore:(CNContactStore *)store NS_DESIGNATED_INITIALIZER;

- (nullable CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *)changeHistoryFetchResult:(CNChangeHistoryFetchRequest *)request
                                      error:(NSError *__autoreleasing  _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
