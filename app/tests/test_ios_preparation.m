#import <Foundation/Foundation.h>
#import "sys/macos/ios_preparation.h"
#include <assert.h>

static NSString *payload(id address, id uptime) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"address":address, @"uptime":uptime}
        options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

int main(void) {
    @autoreleasepool {
        NSString *address = @"fd00::1";
        NSDictionary *fresh = SCIOSPreparedConnectionDetails(payload(address, @100), 101);
        assert([fresh[@"connectionProperties"][@"tunnelIPAddress"] isEqual:address]);
        assert(SCIOSPreparedConnectionDetails(payload(address, @100), 106));
        assert(!SCIOSPreparedConnectionDetails(payload(address, @100), 106.01));
        assert(!SCIOSPreparedConnectionDetails(payload(address, @100), 99));
        assert(!SCIOSPreparedConnectionDetails(payload(@"127.0.0.1", @100), 101));
        assert(!SCIOSPreparedConnectionDetails(payload(@"not an address", @100), 101));
        assert(!SCIOSPreparedConnectionDetails(payload(@12, @100), 101));
        assert(!SCIOSPreparedConnectionDetails(payload(address, @"100"), 101));
        assert(!SCIOSPreparedConnectionDetails(@"[]", 101));
        assert(!SCIOSPreparedConnectionDetails(@"broken", 101));
        assert(!SCIOSPreparedConnectionDetails(nil, 101));
        puts("Prepared tunnel validity, expiry, clock reversal and malformed handoff rejection passed.");
    }
    return 0;
}
