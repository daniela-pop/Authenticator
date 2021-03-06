//
//  OTPAuthURL.m
//
//  Copyright 2011 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not
//  use this file except in compliance with the License.  You may obtain a copy
//  of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
//  License for the specific language governing permissions and limitations under
//  the License.
//

#import "OTPAuthURL.h"

#import <Security/Security.h>

#import "OTPDefines.h"

#import "NSURL+OTPURLArguments.h"
#import "NSString+OTPURLArguments.h"
#import "NSData+OTPBase32Encoding.h"
#import "HOTPGenerator.h"
#import "TOTPGenerator.h"

static NSString *const kOTPAuthScheme = @"otpauth";
static NSString *const kTOTPAuthScheme = @"totp";
static NSString *const kOTPService = @"com.google.otp.authentication";
// These are keys in the otpauth:// query string.
static NSString *const kQueryAlgorithmKey = @"algorithm";
static NSString *const kQuerySecretKey = @"secret";
static NSString *const kQueryCounterKey = @"counter";
static NSString *const kQueryDigitsKey = @"digits";
static NSString *const kQueryPeriodKey = @"period";

static NSString *const kBase32Charset = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
static NSString *const kBase32Synonyms =
    @"AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz";
static NSString *const kBase32Sep = @" -";

static const NSTimeInterval kTOTPDefaultSecondsBeforeChange = 5;
NSString *const OTPAuthURLWillGenerateNewOTPWarningNotification
  = @"OTPAuthURLWillGenerateNewOTPWarningNotification";
NSString *const OTPAuthURLDidGenerateNewOTPNotification
  = @"OTPAuthURLDidGenerateNewOTPNotification";
NSString *const OTPAuthURLSecondsBeforeNewOTPKey
  = @"OTPAuthURLSecondsBeforeNewOTP";

@interface OTPAuthURL ()

@property (strong, nonatomic, readwrite) NSData *keychainItemRef;
@property (strong, nonatomic) OTPGenerator *generator;

// Initialize an OTPAuthURL with a dictionary of attributes from a keychain.
+ (OTPAuthURL *)authURLWithKeychainDictionary:(NSDictionary *)dict;

// Initialize an OTPAuthURL object with an otpauth:// NSURL object.
- (id)initWithOTPGenerator:(OTPGenerator *)generator
                      name:(NSString *)name;

@end

@interface TOTPAuthURL ()
@property (nonatomic, readwrite, assign) NSTimeInterval lastProgress;
@property (nonatomic, readwrite, assign) BOOL warningSent;

+ (void)totpTimer:(NSTimer *)timer;
- (id)initWithTOTPURL:(NSURL *)url;
- (id)initWithName:(NSString *)name
            secret:(NSData *)secret
         algorithm:(NSString *)algorithm
            digits:(uint32_t)digits
             query:(NSDictionary *)query;
@end

@interface HOTPAuthURL ()
+ (BOOL)isValidCounter:(NSString *)counter;
- (id)initWithName:(NSString *)name
            secret:(NSData *)secret
         algorithm:(NSString *)algorithm
            digits:(uint32_t)digits
             query:(NSDictionary *)query;
@property(readwrite, copy, nonatomic) NSString *otpCode;

@end

@implementation OTPAuthURL

+ (OTPAuthURL *)authURLWithURL:(NSURL *)url
                        secret:(NSData *)secret {
  OTPAuthURL *authURL = nil;
  NSString *urlScheme = [url scheme];
  if ([urlScheme isEqualToString:kTOTPAuthScheme]) {
    // Convert totp:// into otpauth://
    authURL = [[TOTPAuthURL alloc] initWithTOTPURL:url];
  } else if (![urlScheme isEqualToString:kOTPAuthScheme]) {
    // Required (otpauth://)
    OTPDevLog(@"invalid scheme: %@", [url scheme]);
  } else {
    NSString *path = [url path];
    if ([path length] > 1) {
      // Optional UTF-8 encoded human readable description (skip leading "/")
      NSString *name = [[url path] substringFromIndex:1];

      NSDictionary *query = [url otp_dictionaryWithQueryArguments];

      // Optional algorithm=(SHA1|SHA256|SHA512|MD5) defaults to SHA1
      NSString *algorithm = query[kQueryAlgorithmKey];
      if (!algorithm) {
        algorithm = [OTPGenerator defaultAlgorithm];
      }
      if (!secret) {
        // Required secret=Base32EncodedKey
        NSString *secretString = query[kQuerySecretKey];
        secret = [[NSData alloc] otp_initWithBase32EncodedString:secretString options:OTPDataBase32DecodingCaseInsensitive|OTPDataBase32DecodingIgnoreSpaces];
      }
      // Optional digits=[68] defaults to 8
      NSString *digitString = query[kQueryDigitsKey];
      uint32_t digits = 0;
      if (!digitString) {
        digits = [OTPGenerator defaultDigits];
      } else {
        digits = [digitString intValue];
      }

      NSString *type = [url host];
      if ([type isEqualToString:@"hotp"]) {
        authURL = [[HOTPAuthURL alloc] initWithName:name
                                              secret:secret
                                           algorithm:algorithm
                                              digits:digits
                                               query:query];
      } else if ([type isEqualToString:@"totp"]) {
        authURL = [[TOTPAuthURL alloc] initWithName:name
                                              secret:secret
                                           algorithm:algorithm
                                              digits:digits
                                               query:query];
      }
    }
  }
  return authURL;
}

+ (OTPAuthURL *)authURLWithKeychainItemRef:(NSData *)data {
	OTPAuthURL *authURL = nil;
	NSDictionary *query = @{
					 (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecValuePersistentRef: data,
		  (__bridge id)kSecReturnAttributes: @YES,
				(__bridge id)kSecReturnData: @YES
	};
	CFDictionaryRef result = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
  if (status == noErr) {
    authURL = [self authURLWithKeychainDictionary:(__bridge_transfer NSDictionary *)result];
    [authURL setKeychainItemRef:data];
  }
  return authURL;
}

+ (OTPAuthURL *)authURLWithKeychainDictionary:(NSDictionary *)dict {
  NSData *urlData = dict[(__bridge id)kSecAttrGeneric];
  NSData *secretData = dict[(__bridge id)kSecValueData];
  NSString *urlString = [[NSString alloc] initWithData:urlData
                                               encoding:NSUTF8StringEncoding];
  NSURL *url = [NSURL URLWithString:urlString];
  return  [self authURLWithURL:url secret:secretData];
}

- (id)initWithOTPGenerator:(OTPGenerator *)generator name:(NSString *)name {
	if (!generator || !name) {
		OTPDevLog(@"Bad Args Generator:%@ Name:%@", generator, name);
		return (self = nil);
	}
	
	self = [super init];
	if (self) {
		self.generator = generator;
		self.name = name;
	}
	return self;
}

- (id)init {
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}


- (NSURL *)url {
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}

- (BOOL)saveToKeychain {
  NSString *urlString = [[self url] absoluteString];
  NSData *urlData = [urlString dataUsingEncoding:NSUTF8StringEncoding];

  NSMutableDictionary *attributes =
   [NSMutableDictionary dictionaryWithObject:urlData
                                      forKey:(__bridge id)kSecAttrGeneric];
  OSStatus status;

  if ([self isInKeychain]) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecValuePersistentRef: self.keychainItemRef};

    status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);

    OTPDevLog(@"SecItemUpdate(%@, %@) = %d", query, attributes, (int)status);
  } else {
    attributes[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    attributes[(__bridge id)kSecReturnPersistentRef] = (id)kCFBooleanTrue;
    attributes[(__bridge id)kSecValueData] = self.generator.secret;
    attributes[(__bridge id)kSecAttrService] = kOTPService;
	  CFDataRef ref = NULL;

    // The name here has to be unique or else we will get a errSecDuplicateItem
    // so if we have two items with the same name, we will just append a
    // random number on the end until we get success. We will try at max of
    // 1000 times so as to not hang in shut down.
    // We do not display this name to the user, so anything will do.
    NSString *name = self.name;
    for (int i = 0; i < 1000; i++) {
      attributes[(__bridge id)kSecAttrAccount] = name;
      status = SecItemAdd((__bridge CFDictionaryRef)attributes, (CFTypeRef *)&ref);
      if (status == errSecDuplicateItem) {
        name = [NSString stringWithFormat:@"%@.%ld", self.name, random()];
      } else {
        break;
      }
    }
    OTPDevLog(@"SecItemAdd(%@, %@) = %d", attributes, ref, (int)status);

    if (status == noErr) {
      self.keychainItemRef = (__bridge_transfer NSData *)ref;
    }
  }

  return status == noErr;
}

- (BOOL)removeFromKeychain {
  if (![self isInKeychain]) {
    return NO;
  }
  NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecValuePersistentRef: [self keychainItemRef]};
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);

  OTPDevLog(@"SecItemDelete(%@) = %d", query, (int)status);

  if (status == noErr) {
    [self setKeychainItemRef:nil];
  }
  return status == noErr;
}

- (BOOL)isInKeychain {
  return self.keychainItemRef != nil;
}

- (void)generateNextOTPCode {
  OTPDevLog(@"Called generateNextOTPCode on a non-HOTP generator");
}

- (NSString*)checkCode {
  return [self.generator generateOTPForCounter:0];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<%@ %p> Name: %@ ref: %p checkCode: %@",
          [self class], self, self.name, self.keychainItemRef, self.checkCode];
}

#pragma mark -
#pragma mark URL Validation


@end

@implementation TOTPAuthURL
static NSString *const TOTPAuthURLTimerNotification
  = @"TOTPAuthURLTimerNotification";

@synthesize generationAdvanceWarning = generationAdvanceWarning_;
@synthesize lastProgress = lastProgress_;
@synthesize warningSent = warningSent_;

+ (void)initialize {
  static NSTimer *sTOTPTimer = nil;
  if (!sTOTPTimer) {
    @autoreleasepool {
      sTOTPTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                    target:self
                                                  selector:@selector(totpTimer:)
                                                  userInfo:nil
                                                   repeats:YES];
    }
  }
}

+ (void)totpTimer:(NSTimer *)timer {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:TOTPAuthURLTimerNotification object:self];
}

- (id)initWithOTPGenerator:(OTPGenerator *)generator
                      name:(NSString *)name {
  if ((self = [super initWithOTPGenerator:generator
                                     name:name])) {
    [self setGenerationAdvanceWarning:kTOTPDefaultSecondsBeforeChange];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(totpTimer:)
                                                 name:TOTPAuthURLTimerNotification
                                               object:nil];
  }
  return self;
}

- (id)initWithSecret:(NSData *)secret name:(NSString *)name {
  TOTPGenerator *generator
    = [[TOTPGenerator alloc] initWithSecret:secret
                                   algorithm:[TOTPGenerator defaultAlgorithm]
                                      digits:[TOTPGenerator defaultDigits]
                                      period:[TOTPGenerator defaultPeriod]];
  return [self initWithOTPGenerator:generator
                               name:name];
}

// totp:// urls are generated by the GAIA smsauthconfig page and implement
// a subset of the functionality available in otpauth:// urls, so we just
// translate to that internally.
- (id)initWithTOTPURL:(NSURL *)url {
  NSMutableString *name = nil;
  if ([[url user] length]) {
    name = [NSMutableString stringWithString:[url user]];
  }
  if ([url host]) {
    [name appendFormat:@"@%@", [url host]];
  }
    
  NSData *secret = [[NSData alloc] otp_initWithBase32EncodedString:url.fragment options:OTPDataBase32DecodingCaseInsensitive|OTPDataBase32DecodingIgnoreSpaces];
  return [self initWithSecret:secret name:name];
}

- (id)initWithName:(NSString *)name
            secret:(NSData *)secret
         algorithm:(NSString *)algorithm
            digits:(uint32_t)digits
             query:(NSDictionary *)query {
  NSString *periodString = query[kQueryPeriodKey];
  NSTimeInterval period = 0;
  if (periodString) {
    period = [periodString doubleValue];
  } else {
    period = [TOTPGenerator defaultPeriod];
  }

  TOTPGenerator *generator
    = [[TOTPGenerator alloc] initWithSecret:secret
                                   algorithm:algorithm
                                      digits:digits
                                      period:period];

  if ((self = [self initWithOTPGenerator:generator
                                    name:name])) {
    self.lastProgress = period;
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)otpCode {
  return [self.generator generateOTP];
}

- (void)totpTimer:(NSTimer *)timer {
  TOTPGenerator *generator = (TOTPGenerator *)[self generator];
  NSTimeInterval delta = [[NSDate date] timeIntervalSince1970];
  NSTimeInterval period = [generator period];
  NSTimeInterval progress = (NSTimeInterval)((uint64_t)delta % (uint64_t)period);
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  if (progress == 0 || progress > self.lastProgress) {
    [nc postNotificationName:OTPAuthURLDidGenerateNewOTPNotification object:self];
    self.lastProgress = period;
    self.warningSent = NO;
  } else if (progress > period - self.generationAdvanceWarning
             && !self.warningSent) {
    NSDictionary *userInfo
      = @{OTPAuthURLSecondsBeforeNewOTPKey: @(ceil(progress))};

    [nc postNotificationName:OTPAuthURLWillGenerateNewOTPWarningNotification
                      object:self
                    userInfo:userInfo];
    self.warningSent = YES;
  }
}

- (NSURL *)url {

  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  TOTPGenerator *generator = (TOTPGenerator *)[self generator];
  Class generatorClass = [generator class];

  NSString *algorithm = [generator algorithm];
  if (![algorithm isEqualToString:[generatorClass defaultAlgorithm]]) {
    query[kQueryAlgorithmKey] = algorithm;
  }

  NSUInteger digits = [generator digits];
  if (digits != [generatorClass defaultDigits]) {
    id val = @(digits);
    query[kQueryDigitsKey] = val;
  }

  NSTimeInterval period = [generator period];
  if (fpclassify(period - [generatorClass defaultPeriod]) != FP_ZERO) {
    query[kQueryPeriodKey] = @(period);
  }

  return [NSURL URLWithString:[NSString stringWithFormat:@"%@://totp/%@?%@",
                                                         kOTPAuthScheme,
                                                         [self.name otp_stringByEscapingForURLArgument],
                                                         [NSURL otp_queryArgumentsForDictionary:query]]];
}

@end

@implementation HOTPAuthURL

@synthesize otpCode = otpCode_;

- (id)initWithOTPGenerator:(OTPGenerator *)generator
               name:(NSString *)name {
  if ((self = [super initWithOTPGenerator:generator name:name])) {
    int64_t counter = [(HOTPGenerator *)generator counter];
    self.otpCode = [generator generateOTPForCounter:counter];
  }
  return self;
}


- (id)initWithSecret:(NSData *)secret name:(NSString *)name {
  HOTPGenerator *generator
    = [[HOTPGenerator alloc] initWithSecret:secret
                                   algorithm:[HOTPGenerator defaultAlgorithm]
                                      digits:[HOTPGenerator defaultDigits]
                                     counter:[HOTPGenerator defaultInitialCounter]];
  return [self initWithOTPGenerator:generator name:name];
}

- (id)initWithName:(NSString *)name
            secret:(NSData *)secret
         algorithm:(NSString *)algorithm
            digits:(uint32_t)digits
             query:(NSDictionary *)query {
  NSString *counterString = query[kQueryCounterKey];
  if ([[self class] isValidCounter:counterString]) {
    NSScanner *scanner = [NSScanner scannerWithString:counterString];
    uint64_t counter;
    BOOL goodScan = [scanner scanUnsignedLongLong:&counter];
    // Good scan should always be good based on the isValidCounter check above.
    NSAssert(goodScan, @"goodscan should be true: %c", goodScan);
    HOTPGenerator *generator
      = [[HOTPGenerator alloc] initWithSecret:secret
                                     algorithm:algorithm
                                        digits:digits
                                       counter:counter];
    return (self = [self initWithOTPGenerator:generator name:name]);
  } else {
    OTPDevLog(@"invalid counter: %@", counterString);
    return (self = [super initWithOTPGenerator:nil name:nil]);
  }
}


- (void)generateNextOTPCode {
  self.otpCode = [[self generator] generateOTP];
  [self saveToKeychain];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:OTPAuthURLDidGenerateNewOTPNotification object:self];
}

- (NSURL *)url {
  NSMutableDictionary *query = [NSMutableDictionary dictionary];

  HOTPGenerator *generator = (HOTPGenerator *)[self generator];
  Class generatorClass = [generator class];

  NSString *algorithm = [generator algorithm];
  if (![algorithm isEqualToString:[generatorClass defaultAlgorithm]]) {
    query[kQueryAlgorithmKey] = algorithm;
  }

  NSUInteger digits = [generator digits];
  if (digits != [generatorClass defaultDigits]) {
    id val = @(digits);
    query[kQueryDigitsKey] = val;
  }

  uint64_t counter = [generator counter];
  id val = @(counter);
  query[kQueryCounterKey] = val;

  return [NSURL URLWithString:[NSString stringWithFormat:@"%@://hotp/%@?%@",
                                                         kOTPAuthScheme,
                                                         [[self name] otp_stringByEscapingForURLArgument],
                                                         [NSURL otp_queryArgumentsForDictionary:query]]];
}

+ (BOOL)isValidCounter:(NSString *)counter {
  NSCharacterSet *nonDigits =
    [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
  NSRange pos = [counter rangeOfCharacterFromSet:nonDigits];
  return pos.location == NSNotFound;
}

@end

