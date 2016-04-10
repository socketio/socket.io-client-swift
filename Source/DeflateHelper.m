//
//  DeflateHelper.m
//  Socket.IO-Client-Swift
//
//  Created by Danny Ricciotti on 4/10/16.
//
//

#import "DeflateHelper.h"
#import <zlib.h>

@interface DeflateHelper()
//@property z_stream inflator;
@end


@implementation DeflateHelper

/**
 * Inflates a websocket payload.
 * The default values in socket.io are {"flush":2,"windowBits":15,"memLevel":8}
 */
- (NSData *)inflate:(NSData *)data {
    
    z_stream _inflator = {0};
    inflateInit2(&_inflator, -15);
    
    NSMutableData *output = [NSMutableData data];
    
    NSInteger inputLength = data.length;
    
    size_t consumedInput = 0;
    while (consumedInput < inputLength ) {
        NSUInteger outputPosition = output.length;
        [output setLength:outputPosition + 4096];
        NSUInteger availableOutput = output.length - outputPosition;
        NSUInteger remainingInput = inputLength - consumedInput;
        _inflator.next_in = (Bytef *) (data.bytes + consumedInput);
        _inflator.avail_in = remainingInput;
        _inflator.next_out = output.mutableBytes + outputPosition;
        _inflator.avail_out = availableOutput;
        int result = inflate(&_inflator, Z_NO_FLUSH);
        consumedInput += remainingInput - _inflator.avail_in;
        [output setLength:outputPosition + availableOutput - _inflator.avail_out];
        
        // TODO: Handle buffer errors and steam_end conditions
        if (result == Z_BUF_ERROR) {
            continue;
        }
        if (result == Z_STREAM_END) {
            //            inflateReset(&_inflator);
            continue;
        }
        if (result != Z_OK) {
            inflateEnd(&_inflator);
            return nil;
        }
    }
    
    inflateEnd(&_inflator);
    return output;
}

@end
