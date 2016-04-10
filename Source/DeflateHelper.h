//
//  DeflateHelper.h
//  Socket.IO-Client-Swift
//
//  Created by Danny Ricciotti on 4/10/16.
//
//

#import <Foundation/Foundation.h>

@interface DeflateHelper : NSObject


- (NSData *)inflate:(NSData *)data;

@end
