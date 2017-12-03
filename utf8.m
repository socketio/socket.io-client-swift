//
//  utf8.m
//  utf8
//
//  Created by tom on 29/11/2017.
//  Copyright © 2017 tom. All rights reserved.
//

#import "utf8.h"
#import <Foundation/Foundation.h>

NSString *INVALID_BYTE_INDEX = @"Invalid byte index";
NSString *INVALID_CONTINUATION_BYTE = @"Invalid continuation byte";
int byteCount;
int byteIndex;

@interface utf8 ()
@property (nonatomic, strong) NSMutableArray<NSString*> *byteArray;
@end

@implementation utf8
- (NSString*)decode:(NSString*)string {
    @synchronized(self) {
        NSString *str = nil;
        @try {
            str = [self decode_:string];
#if DEBUG
            NSLog(@"\n utf8.decode str == %@ \n", str);
#endif
        } @catch(NSException *exception) {
#if DEBUG
            NSLog(@"\n exception.reason == %@ \n", exception.name);
#endif
        } @finally {
#if DEBUG
            NSLog(@"finally");
#endif
        }
        return str;
    }
}

- (NSString *)decode_:(NSString *)byteString {
    // get byteArray & byteCount
    [self ucs2decode:byteString pLength:&byteCount];
    byteIndex = 0;
    NSMutableArray <NSNumber*>*codePoints = NSMutableArray.new;
    int tmp;
    while ((tmp = [self decodeSymbol]) != -1) {
        [codePoints addObject:@(tmp)];
    }
    return ucs2encode(listToArray(codePoints));
}

-(int)decodeSymbol {
    int byte1;
    int byte2;
    int byte3;
    int byte4;
    int codePoint;

    if (byteIndex > byteCount) {
        @throw [NSException
                exceptionWithName:INVALID_BYTE_INDEX
                reason:nil
                userInfo:nil];
    }

    if (byteIndex == byteCount) {
        return -1;
    }

    byte1 = [self.byteArray[byteIndex] characterAtIndex:0] & 0xFF;
    byteIndex++;
    
    if ((byte1 & 0x80) == 0) {
        return byte1;
    }

    if ((byte1 & 0xE0) == 0xC0) {
        byte2 = [self readContinuationByte];
        codePoint = ((byte1 & 0x1F) << 6) | byte2;
        if (codePoint >= 0x80) {
            return codePoint;
        } else {
            @throw [NSException
                    exceptionWithName:INVALID_CONTINUATION_BYTE
                    reason:nil
                    userInfo:nil];
        }
    }

    if ((byte1 & 0xF0) == 0xE0) {
        byte2 = [self readContinuationByte];
        byte3 = [self readContinuationByte];
        codePoint = ((byte1 & 0x0F) << 12) | (byte2 << 6) | byte3;
        if (codePoint >= 0x0800) {
            checkScalarValue(codePoint);
            return codePoint;
        } else {
            @throw [NSException
                    exceptionWithName:INVALID_CONTINUATION_BYTE
                    reason:nil
                    userInfo:nil];
        }
    }

    if ((byte1 & 0xF8) == 0xF0) {
        byte2 = [self readContinuationByte];
        byte3 = [self readContinuationByte];
        byte4 = [self readContinuationByte];
        codePoint = ((byte1 & 0x0F) << 0x12) | (byte2 << 0x0C) | (byte3 << 0x06) | byte4;
        if (codePoint >= 0x010000 && codePoint <= 0x10FFFF) {
            return codePoint;
        }
    }
    @throw [NSException
            exceptionWithName:INVALID_CONTINUATION_BYTE
            reason:nil
            userInfo:nil];
}


- (int)readContinuationByte {
    if (byteIndex >= byteCount) {
        @throw [NSException
                exceptionWithName:INVALID_BYTE_INDEX
                reason:nil
                userInfo:nil];
    }

    int continuationByte = [self.byteArray[byteIndex] characterAtIndex:0] & 0xFF;
    byteIndex++;
    
    if ((continuationByte & 0xC0) == 0x80) {
        return continuationByte & 0x3F;
    }

    @throw [NSException
            exceptionWithName:INVALID_CONTINUATION_BYTE
            reason:nil
            userInfo:nil];
}

void checkScalarValue(int codePoint) {
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
        @throw [NSException
                exceptionWithName:[NSString stringWithFormat:@"Lone surrogate U+ + (UNICODE-->)%d(<--UNICODE) + is not a scalar value", codePoint]
                reason:nil
                userInfo:nil];
    }
}

NSArray* listToArray(NSArray<NSNumber*>* list) {
    long size = list.count;
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:size];
    for (int i = 0; i < size; i++) {
        array[i] = list[i];
    }
    return array;
}

NSString* ucs2encode(NSArray<NSNumber*>* array) {
    unichar c;
    NSString *s = NSString.new;
    for (NSNumber *unicode in array) {
        c = [unicode intValue];
        s = [s stringByAppendingString:[NSString stringWithCharacters:&c length:1]];
    }
    return s;
}

-(void)ucs2decode:(NSString *)string pLength:(int*) pLength {
    u_long len = string.length;
    self.byteArray = NSMutableArray.new;
    int j = 0;
    unichar value;
    for (int i = 0; i < len; ++ i ) {
        value = [string characterAtIndex:i];
        [self.byteArray addObject:[NSString stringWithCharacters:&value length:1]];
        j++;
    }
    if (pLength) {
        *pLength = j;
    }
}

long codePointCount(const char*string) {
    return strlen(string);
}

char codePointAt(char *string, int i) {
    return string[i];
}

@end
