//
//  OwnTracksAppDelegate.m
//  OwnTracks
//
//  Created by Christoph Krey on 03.02.14.
//  Copyright (c) 2014-2015 OwnTracks. All rights reserved.
//

#import "OwnTracksAppDelegate.h"
#import "CoreData.h"
#import "Friend+Create.h"
#import "Location+Create.h"
#import "Setting+Create.h"
#import "AlertView.h"
#import "Settings.h"
#import <NotificationCenter/NotificationCenter.h>
#import <Fabric/Fabric.h>
#import <Crashlytics/Crashlytics.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

@interface OwnTracksAppDelegate()
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (strong, nonatomic) void (^completionHandler)(UIBackgroundFetchResult);
@property (strong, nonatomic) CoreData *coreData;
@property (nonatomic) BOOL publicWarning;
@property (strong, nonatomic) CMStepCounter *stepCounter;
@property (strong, nonatomic) CMPedometer *pedometer;

@property (strong, nonatomic) NSManagedObjectContext *queueManagedObjectContext;
@end

#define MAX_OTHER_LOCATIONS 1

@implementation OwnTracksAppDelegate
static const DDLogLevel ddLogLevel = DDLogLevelError;

#pragma ApplicationDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    //NSLog(@"willFinishLaunchingWithOptions");
    NSEnumerator *enumerator = [launchOptions keyEnumerator];
    NSString *key;
    while ((key = [enumerator nextObject])) {
        //NSLog(@"%@:%@", key, [[launchOptions objectForKey:key] description]);
    }
    
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.completionHandler = nil;
    
    if ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"] != NSOrderedAscending) {
        //NSLog(@"setMinimumBackgroundFetchInterval %f", UIApplicationBackgroundFetchIntervalMinimum);
        [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
    }
    
    if ([[[UIDevice currentDevice] systemVersion] compare:@"8.0"] != NSOrderedAscending) {
        UIUserNotificationSettings *settings = [UIUserNotificationSettings settingsForTypes:
                                                UIUserNotificationTypeAlert |
                                                UIUserNotificationTypeBadge
                                                                                 categories:[NSSet setWithObjects:nil]];
        // NSLog(@"registerUserNotificationSettings %@", settings);
        [application registerUserNotificationSettings:settings];
    }
    
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Fabric with:@[CrashlyticsKit]];
    
#ifdef DEBUG
    [DDLog addLogger:[DDTTYLogger sharedInstance] withLevel:DDLogLevelAll];
#else
    [DDLog addLogger:[DDTTYLogger sharedInstance] withLevel:DDLogLevelError];
#endif
    
    [DDLog addLogger:[DDASLLogger sharedInstance] withLevel:DDLogLevelError];
    
    DDLogVerbose(@"ddLogLevel %lu", (unsigned long)ddLogLevel);
    DDLogVerbose(@"didFinishLaunchingWithOptions");
    
    NSEnumerator *enumerator = [launchOptions keyEnumerator];
    NSString *key;
    while ((key = [enumerator nextObject])) {
        DDLogVerbose(@"%@:%@", key, [[launchOptions objectForKey:key] description]);
    }
    
    
    self.coreData = [[CoreData alloc] init];
    self.inQueue = @(0);
    
    UIDocumentState state;
    
    do {
        state = self.coreData.documentState;
        if (state & UIDocumentStateClosed || ![CoreData theManagedObjectContext]) {
            DDLogVerbose(@"documentState 0x%02lx theManagedObjectContext %@",
                         (long)self.coreData.documentState,
                         [CoreData theManagedObjectContext]);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        }
    } while (state & UIDocumentStateClosed || ![CoreData theManagedObjectContext]);
    
    if (![Setting existsSettingWithKey:@"mode"
                inManagedObjectContext:[CoreData theManagedObjectContext]]) {
        if (![Setting existsSettingWithKey:@"host_preference"
                    inManagedObjectContext:[CoreData theManagedObjectContext]]) {
            [Settings setInt:2 forKey:@"mode"];
            self.publicWarning = TRUE;
        } else {
            [Settings setInt:0 forKey:@"mode"];
        }
    }
    
    [self share];
    
    self.connectionOut = [[Connection alloc] init];
    self.connectionOut.delegate = self;
    [self.connectionOut start];
    
    self.connectionIn = [[Connection alloc] init];
    self.connectionIn.delegate = self;
    [self.connectionIn start];
    
    [self connect];
    
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:TRUE];
    
    LocationManager *locationManager = [LocationManager sharedInstance];
    locationManager.delegate = self;
    locationManager.monitoring = [Settings intForKey:@"monitoring_preference"];
    locationManager.ranging = [Settings boolForKey:@"ranging_preference"];
    locationManager.minDist = [Settings doubleForKey:@"mindist_preference"];
    locationManager.minTime = [Settings doubleForKey:@"mintime_preference"];
    self.messaging = [[Messaging alloc] init];
    [locationManager start];
    
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [self share];
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation {
    DDLogVerbose(@"openURL %@ from %@ annotation %@", url, sourceApplication, annotation);
    
    if (url) {
        DDLogVerbose(@"URL scheme %@", url.scheme);
        
        if ([url.scheme isEqualToString:@"owntracks"]) {
            DDLogVerbose(@"URL path %@ query %@", url.path, url.query);
            
            NSMutableDictionary *queryStrings = [[NSMutableDictionary alloc] init];
            for (NSString *parameter in [url.query componentsSeparatedByString:@"&"]) {
                NSArray *pair = [parameter componentsSeparatedByString:@"="];
                if (pair.count == 2) {
                    NSString *key = pair[0];
                    NSString *value = pair[1];
                    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
                    value = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                    queryStrings[key] = value;
                }
            }
            if ([url.path isEqualToString:@"/beacon"]) {
                NSString *name = queryStrings[@"name"];
                NSString *uuid = queryStrings[@"uuid"];
                int major = [queryStrings[@"major"] intValue];
                int minor = [queryStrings[@"minor"] intValue];
                
                NSString *desc = [NSString stringWithFormat:@"%@:%@%@%@",
                                  name,
                                  uuid,
                                  major ? [NSString stringWithFormat:@":%d", major] : @"",
                                  minor ? [NSString stringWithFormat:@":%d", minor] : @""
                                  ];
                
                [Settings waypointsFromDictionary:@{@"_type":@"waypoints",
                                                    @"waypoints":@[@{@"_type":@"waypoint",
                                                                     @"desc":desc,
                                                                     @"tst":@((int)([[NSDate date] timeIntervalSince1970])),
                                                                     @"lat":@([LocationManager sharedInstance].location.coordinate.latitude),
                                                                     @"lon":@([LocationManager sharedInstance].location.coordinate.longitude),
                                                                     @"rad":@(-1)
                                                                     }]
                                                    }];
                self.processingMessage = @"Beacon QR successfully processed";
                return TRUE;
            } else if ([url.path isEqualToString:@"/hosted"]) {
                NSString *user = queryStrings[@"user"];
                NSString *device = queryStrings[@"device"];
                NSString *token = queryStrings[@"token"];
                
                [[LocationManager sharedInstance] resetRegions];
                NSArray *friends = [Friend allFriendsInManagedObjectContext:[CoreData theManagedObjectContext]];
                for (Friend *friend in friends) {
                    [[CoreData theManagedObjectContext] deleteObject:friend];
                }
                
                
                [Settings fromDictionary:@{@"_type":@"configuration",
                                           @"mode":@(1),
                                           @"username":user,
                                           @"deviceId":device,
                                           @"password":token
                                           }];
                self.configLoad = [NSDate date];
                [CoreData saveContext];
                self.processingMessage = @"Hosted QR successfully processed";
                return TRUE;
            } else {
                self.processingMessage = [NSString stringWithFormat:@"unkown url path %@",
                                          url.path];
                return FALSE;
            }
        } else if ([url.scheme isEqualToString:@"file"]) {
            NSInputStream *input = [NSInputStream inputStreamWithURL:url];
            if ([input streamError]) {
                self.processingMessage = [NSString stringWithFormat:@"inputStreamWithURL %@ %@",
                                          [input streamError],
                                          url];
                return FALSE;
            }
            [input open];
            if ([input streamError]) {
                self.processingMessage = [NSString stringWithFormat:@"open %@ %@",
                                          [input streamError],
                                          url];
                return FALSE;
            }
            
            DDLogVerbose(@"URL pathExtension %@", url.pathExtension);
            
            NSError *error;
            NSString *extension = [url pathExtension];
            if ([extension isEqualToString:@"otrc"] || [extension isEqualToString:@"mqtc"]) {
                [[LocationManager sharedInstance] resetRegions];
                NSArray *friends = [Friend allFriendsInManagedObjectContext:[CoreData theManagedObjectContext]];
                for (Friend *friend in friends) {
                    [[CoreData theManagedObjectContext] deleteObject:friend];
                }
                error = [Settings fromStream:input];
                [CoreData saveContext];
            } else if ([extension isEqualToString:@"otrw"] || [extension isEqualToString:@"mqtw"]) {
                error = [Settings waypointsFromStream:input];
            } else {
                error = [NSError errorWithDomain:@"OwnTracks"
                                            code:2
                                        userInfo:@{@"extension":extension ? extension : @"(null)"}];
            }
            
            if (error) {
                self.processingMessage = [NSString stringWithFormat:@"Error processing file %@: %@ %@",
                                          [url lastPathComponent],
                                          error.localizedDescription,
                                          error.userInfo];
                return FALSE;
            }
            self.processingMessage = [NSString stringWithFormat:@"File %@ successfully processed",
                                      [url lastPathComponent]];
            self.configLoad = [NSDate date];
            return TRUE;
        } else {
            self.processingMessage = [NSString stringWithFormat:@"unkown url scheme %@",
                                      url.scheme];
            return FALSE;
        }
    }
    self.processingMessage = [NSString stringWithFormat:@"no url specified"];
    return FALSE;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    DDLogVerbose(@"applicationDidEnterBackground");
    self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        DDLogVerbose(@"BackgroundTaskExpirationHandler");
        /*
         * we might end up here if the connection could not be closed within the given
         * background time
         */
        if (self.backgroundTask) {
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    }];
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    DDLogVerbose(@"applicationDidBecomeActive");
    
    if (self.publicWarning) {
        [AlertView alert:@"Public Mode" message:@"In public mode, your location is published anonymously to owntracks.org's shared broker. Find more information or change in Settings"];
        self.publicWarning = FALSE;
    }
    
    if (self.processingMessage) {
        [AlertView alert:@"openURL" message:self.processingMessage];
        self.processingMessage = nil;
        [self reconnect];
    }
    
    if (self.coreData.documentState) {
        NSString *message = [NSString stringWithFormat:@"documentState 0x%02lx %@",
                             (long)self.coreData.documentState,
                             self.coreData.fileURL];
        [AlertView alert:@"CoreData" message:message];
    }
    
    if (![Settings validIds]) {
        NSString *message = [NSString stringWithFormat:@"To publish your location userID and deviceID must be set"];
        [AlertView alert:@"Settings" message:message];
    }
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    DDLogVerbose(@"performFetchWithCompletionHandler");
    self.completionHandler = completionHandler;
    [[LocationManager sharedInstance] wakeup];
    [self.connectionOut connectToLast];
    [self.connectionIn connectToLast];
    
    if ([LocationManager sharedInstance].monitoring) {
        CLLocation *lastLocation = [LocationManager sharedInstance].location;
        CLLocation *location = [[CLLocation alloc] initWithLatitude:lastLocation.coordinate.latitude
                                                          longitude:lastLocation.coordinate.longitude];
        [self publishLocation:location
                    automatic:TRUE
                        addon:@{@"t":@"p"}];
    }
}

- (void)application:(UIApplication *)application didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
    DDLogVerbose(@"didRegisterUserNotificationSettings %@", notificationSettings);
}

/*
 *
 * LocationManagerDelegate
 *
 */

- (void)newLocation:(CLLocation *)location {
    [self publishLocation:location automatic:YES addon:nil];
    [self.messaging newLocation:location.coordinate.latitude
                longitude:location.coordinate.longitude
                  context:[CoreData theManagedObjectContext]];
    [self share];
}

- (void)timerLocation:(CLLocation *)location {
    [self publishLocation:location automatic:YES addon:@{@"t": @"t"}];
    [self.messaging newLocation:location.coordinate.latitude
                longitude:location.coordinate.longitude
                  context:[CoreData theManagedObjectContext]];
}

- (void)regionEvent:(CLRegion *)region enter:(BOOL)enter {
    NSString *message = [NSString stringWithFormat:@"%@ %@", (enter ? @"Entering" : @"Leaving"), region.identifier];
    [self notification:message userInfo:nil];
    
    Friend *myself = [Friend existsFriendWithTopic:[Settings theGeneralTopic] inManagedObjectContext:[CoreData theManagedObjectContext]];
    CLLocation *location = [LocationManager sharedInstance].location;
    [self.messaging newLocation:location.coordinate.latitude
                longitude:location.coordinate.longitude
                  context:[CoreData theManagedObjectContext]];
    
    NSMutableDictionary *jsonObject = [@{
                                         @"_type": @"transition",
                                         @"lat": @(location.coordinate.latitude),
                                         @"lon": @(location.coordinate.longitude),
                                         @"tst": @(floor([location.timestamp timeIntervalSince1970])),
                                         @"acc": @(location.horizontalAccuracy),
                                         @"tid": [myself getEffectiveTid],
                                         @"event": enter ? @"enter" : @"leave",
                                         @"t": [region isKindOfClass:[CLBeaconRegion class]] ? @"b" : @"c"
                                         } mutableCopy];
    
    for (Location *location in [Location allWaypointsOfTopic:[Settings theGeneralTopic]
                                      inManagedObjectContext:[CoreData theManagedObjectContext]]) {
        if ([region.identifier isEqualToString:location.region.identifier]) {
            location.remark = location.remark; // this touches the location and updates the overlay
            [jsonObject setValue:@(floor([location.timestamp timeIntervalSince1970])) forKey:@"wtst"];
            if ([location.share boolValue]) {
                [jsonObject setValue:region.identifier forKey:@"desc"];
            }
        }
    }
    
    if ([LocationManager sharedInstance].monitoring && [Settings validIds]) {
        [self.connectionOut sendData:[self jsonToData:jsonObject]
                               topic:[[Settings theGeneralTopic] stringByAppendingString:@"/event"]
                                 qos:[Settings intForKey:@"qos_preference"]
                              retain:NO];
        
        if ([region isKindOfClass:[CLBeaconRegion class]]) {
            [self publishLocation:[LocationManager sharedInstance].location automatic:YES addon:@{@"t": @"b"}];
        } else {
            [self publishLocation:[LocationManager sharedInstance].location automatic:YES addon:@{@"t": @"c"}];
        }
    }
}

- (void)regionState:(CLRegion *)region inside:(BOOL)inside {
    CLLocation *location = [LocationManager sharedInstance].location;
    
    for (Location *location in [Location allWaypointsOfTopic:[Settings theGeneralTopic]
                                      inManagedObjectContext:[CoreData theManagedObjectContext]]) {
        if ([region.identifier isEqualToString:location.region.identifier]) {
            location.justcreated = @(![location.justcreated boolValue]); // this is a hack to update the UI
            if ([region isKindOfClass:[CLBeaconRegion class]]) {
                if (location.radius < 0) {
                    location.coordinate = location.coordinate;
                    [self sendWayPoint:location];
                }
            }
        }
    }
    [self.delegate regionState:region inside:inside];
    [self.messaging newLocation:location.coordinate.latitude
                longitude:location.coordinate.longitude
                  context:[CoreData theManagedObjectContext]];
    
}

- (void)beaconInRange:(CLBeacon *)beacon region:(CLBeaconRegion *)region{
    if ([Settings validIds]) {
        NSDictionary *jsonObject = @{
                                     @"_type": @"beacon",
                                     @"tst": @(floor([[LocationManager sharedInstance].location.timestamp timeIntervalSince1970])),
                                     @"uuid": [beacon.proximityUUID UUIDString],
                                     @"major": beacon.major,
                                     @"minor": beacon.minor,
                                     @"prox": @(beacon.proximity),
                                     @"acc": @(round(beacon.accuracy)),
                                     @"rssi": @(beacon.rssi)
                                     };
        [self.connectionOut sendData:[self jsonToData:jsonObject]
                               topic:[[Settings theGeneralTopic] stringByAppendingString:@"/beacon"]
                                 qos:[Settings intForKey:@"qos_preference"]
                              retain:NO];
    }
    [self.delegate beaconInRange:beacon region:region];
}

#pragma ConnectionDelegate

- (void)showState:(Connection *)connection state:(NSInteger)state {
    if (connection == self.connectionOut) {
        self.connectionStateOut = @(state);
    }
    /**
     ** This is a hack to ensure the connection gets gracefully closed at the server
     **
     ** If the background task is ended, occasionally the disconnect message is not received well before the server senses the tcp disconnect
     **/
    
    if ([self.connectionStateOut intValue] == state_closed) {
        if (self.backgroundTask) {
            DDLogVerbose(@"endBackGroundTask");
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
        if (self.completionHandler) {
            DDLogVerbose(@"completionHandler");
            self.completionHandler(UIBackgroundFetchResultNewData);
            self.completionHandler = nil;
        }
    }
}

- (NSManagedObjectContext *)queueManagedObjectContext
{
    if (!_queueManagedObjectContext) {
        _queueManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_queueManagedObjectContext setParentContext:[CoreData theManagedObjectContext]];
    }
    return _queueManagedObjectContext;
}

- (void)handleMessage:(Connection *)connection data:(NSData *)data onTopic:(NSString *)topic retained:(BOOL)retained {
    DDLogVerbose(@"handleMessage");
    
    if ([self.messaging processMessage:topic data:data retained:retained context:self.queueManagedObjectContext]) {
        [self notification:@"New info available"
                  userInfo:@{@"notify": @"msg"}];
        
        return;
    }
    
    NSArray *topicComponents = [topic componentsSeparatedByCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSArray *baseComponents = [[Settings theGeneralTopic] componentsSeparatedByCharactersInSet:
                               [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    
    NSString *device = @"";
    BOOL ownDevice = true;
    
    for (int i = 0; i < [baseComponents count]; i++) {
        if (i > 0) {
            device = [device stringByAppendingString:@"/"];
        }
        if (i < topicComponents.count) {
            device = [device stringByAppendingString:topicComponents[i]];
            if (![baseComponents[i] isEqualToString:topicComponents [i]]) {
                ownDevice = false;
            }
        } else {
            ownDevice = false;
        }
    }
    
    DDLogVerbose(@"device %@", device);
    
    if (ownDevice) {
        
        NSError *error;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (dictionary) {
            if ([dictionary[@"_type"] isEqualToString:@"cmd"]) {
                DDLogVerbose(@"App msg received cmd:%@", dictionary[@"action"]);
                if ([Settings boolForKey:@"cmd_preference"]) {
                    if ([dictionary[@"action"] isEqualToString:@"dump"]) {
                        [self dumpTo:topic];
                    } else if ([dictionary[@"action"] isEqualToString:@"reportLocation"]) {
                        if ([LocationManager sharedInstance].monitoring || [Settings boolForKey:@"allowremotelocation_preference"]) {
                            [self publishLocation:[LocationManager sharedInstance].location
                                        automatic:YES
                                            addon:@{@"t": @"r"}];
                        }
                    } else if ([dictionary[@"action"] isEqualToString:@"reportSteps"]) {
                        [self stepsFrom:dictionary[@"from"] to:dictionary[@"to"]];
                    } else if ([dictionary[@"action"] isEqualToString:@"setWaypoints"]) {
                        NSDictionary *payload = dictionary[@"payload"];
                        [Settings waypointsFromDictionary:payload];
                    } else {
                        DDLogVerbose(@"unknown action %@", dictionary[@"action"]);
                    }
                }
            } else if ([dictionary[@"_type"] isEqualToString:@"card"]) {
                Friend *friend = [Friend friendWithTopic:device
                                                     tid:nil
                                  inManagedObjectContext:[CoreData theManagedObjectContext]];
                [self processFace:friend dictionary:dictionary];
                
            } else {
                DDLogVerbose(@"unhandled record type %@", dictionary[@"_type"]);
            }
        } else {
            DDLogVerbose(@"illegal json %@ %@ %@", error.localizedDescription, error.userInfo, data.description);
        }
        
    } else /* not ownDevice */ {
        @synchronized (self.inQueue) {
            self.inQueue = @([self.inQueue unsignedLongValue] + 1);
        }
        [self.queueManagedObjectContext performBlock:^{
            DDLogVerbose(@"performBlock start");
            if (data.length) {
                
                NSError *error;
                NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (dictionary) {
                    if ([dictionary[@"_type"] isEqualToString:@"location"]) {
                        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(
                                                                                       [dictionary[@"lat"] doubleValue],
                                                                                       [dictionary[@"lon"] doubleValue]
                                                                                       );
                        
                        CLLocation *location = [[CLLocation alloc] initWithCoordinate:coordinate
                                                                             altitude:[dictionary[@"alt"] intValue]
                                                                   horizontalAccuracy:[dictionary[@"acc"] doubleValue]
                                                                     verticalAccuracy:[dictionary[@"vac"] intValue]
                                                                               course:[dictionary[@"cog"] intValue]
                                                                                speed:[dictionary[@"vel"] intValue]
                                                                            timestamp:[NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]]];
                        
                        Location *newLocation = [Location locationWithTopic:device
                                                                        tid:dictionary[@"tid"]
                                                                  timestamp:location.timestamp
                                                                 coordinate:location.coordinate
                                                                   accuracy:location.horizontalAccuracy
                                                                   altitude:location.altitude
                                                           verticalaccuracy:location.verticalAccuracy
                                                                      speed:location.speed
                                                                     course:location.course                                                               automatic:TRUE
                                                                     remark:dictionary[@"desc"]
                                                                     radius:[dictionary[@"rad"] doubleValue]
                                                                      share:NO
                                                     inManagedObjectContext:self.queueManagedObjectContext];
                        [self limitLocationsWith:newLocation.belongsTo
                                       toMaximum:MAX_OTHER_LOCATIONS
                          inManagedObjectContext:self.queueManagedObjectContext];
                        
                    } else if ([dictionary[@"_type"] isEqualToString:@"transition"]) {
                        NSString *type = dictionary[@"t"];
                        if (!type || ![type isEqualToString:@"b"]) {
                            [self notification:[NSString stringWithFormat:@"%@ %@s %@",
                                                dictionary[@"tid"],
                                                dictionary[@"event"],
                                                dictionary[@"desc"]]
                                      userInfo:@{@"notify": @"friend"}];
                        }
                        
                    } else if ([dictionary[@"_type"] isEqualToString:@"card"]) {
                        Friend *friend = [Friend friendWithTopic:device
                                                             tid:nil
                                          inManagedObjectContext:self.queueManagedObjectContext];
                        [self processFace:friend dictionary:dictionary];
                        
                    } else {
                        DDLogVerbose(@"unknown record type %@)", dictionary[@"_type"]);
                    }
                } else {
                    DDLogVerbose(@"illegal json %@, %@ %@)", error.localizedDescription, error.userInfo, data.description);
                }
            } else /* data.length == 0 -> delete friend */ {
                Friend *friend = [Friend existsFriendWithTopic:device inManagedObjectContext:self.queueManagedObjectContext];
                if (friend) {
                    [self.queueManagedObjectContext deleteObject:friend];
                }
            }
            DDLogVerbose(@"performBlock finish");
            @synchronized (self.inQueue) {
                self.inQueue = @([self.inQueue unsignedLongValue] - 1);
            }
            if ([self.inQueue intValue] == 0) {
                [self.queueManagedObjectContext save:nil];
            }
        }];
    }
}

- (void)processFace:(Friend *)friend dictionary:(NSDictionary *)dictionary {
    if (friend) {
        friend.cardName = dictionary[@"name"];
        NSString *string = dictionary[@"face"];
        NSData *imageData = [[NSData alloc] initWithBase64EncodedString:string options:0];
        friend.cardImage = imageData;
        Location *location = [friend newestLocation];
        if (location) {
            location.justcreated = @(![location.justcreated boolValue]); // touch to trigger update
        }
    }
}

- (void)messageDelivered:(Connection *)connection msgID:(UInt16)msgID {
    DDLogVerbose(@"Message delivered id=%u", msgID);
}

- (void)totalBuffered:(Connection *)connection count:(NSUInteger)count {
    DDLogVerbose(@"totalBuffered %lu", (unsigned long)count);
    if (connection == self.connectionOut) {
        self.connectionBufferedOut = @(count);
        [UIApplication sharedApplication].applicationIconBadgeNumber = count;
    }
}

- (void)dumpTo:(NSString *)topic {
    NSDictionary *dumpDict = @{
                               @"_type":@"dump",
                               @"configuration":[Settings toDictionary],
                               };
    
    [self.connectionOut sendData:[self jsonToData:dumpDict]
                           topic:[[Settings theGeneralTopic] stringByAppendingString:@"/dump"]
                             qos:[Settings intForKey:@"qos_preference"]
                          retain:NO];
}

- (void)stepsFrom:(NSNumber *)from to:(NSNumber *)to {
    NSDate *toDate;
    NSDate *fromDate;
    if (to && [to isKindOfClass:[NSNumber class]]) {
        toDate = [NSDate dateWithTimeIntervalSince1970:[to doubleValue]];
    } else {
        toDate = [NSDate date];
    }
    if (from && [from isKindOfClass:[NSNumber class]]) {
        fromDate = [NSDate dateWithTimeIntervalSince1970:[from doubleValue]];
    } else {
        NSDateComponents *components = [[NSCalendar currentCalendar]
                                        components: NSCalendarUnitDay |
                                        NSCalendarUnitHour |
                                        NSCalendarUnitMinute |
                                        NSCalendarUnitSecond |
                                        NSCalendarUnitMonth |
                                        NSCalendarUnitYear
                                        fromDate:toDate];
        components.hour = 0;
        components.minute = 0;
        components.second = 0;
        
        fromDate = [[NSCalendar currentCalendar] dateFromComponents:components];
    }
    
    if ([[[UIDevice currentDevice] systemVersion] compare:@"8.0"] != NSOrderedAscending) {
        DDLogVerbose(@"isStepCountingAvailable %d", [CMPedometer isStepCountingAvailable]);
        DDLogVerbose(@"isFloorCountingAvailable %d", [CMPedometer isFloorCountingAvailable]);
        DDLogVerbose(@"isDistanceAvailable %d", [CMPedometer isDistanceAvailable]);
        if (!self.pedometer) {
            self.pedometer = [[CMPedometer alloc] init];
        }
        [self.pedometer queryPedometerDataFromDate:fromDate
                                            toDate:toDate
                                       withHandler:^(CMPedometerData *pedometerData, NSError *error) {
                                           DDLogVerbose(@"StepCounter queryPedometerDataFromDate handler %ld %ld %ld %ld %@",
                                                        [pedometerData.numberOfSteps longValue],
                                                        [pedometerData.floorsAscended longValue],
                                                        [pedometerData.floorsDescended longValue],
                                                        [pedometerData.distance longValue],
                                                        error.localizedDescription);
                                           dispatch_async(dispatch_get_main_queue(), ^{
                                               
                                               NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
                                               [jsonObject addEntriesFromDictionary:@{
                                                                                      @"_type": @"steps",
                                                                                      @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                                                                      @"from": @(floor([fromDate timeIntervalSince1970])),
                                                                                      @"to": @(floor([toDate timeIntervalSince1970])),
                                                                                      }];
                                               if (pedometerData) {
                                                   [jsonObject setObject:pedometerData.numberOfSteps forKey:@"steps"];
                                                   if (pedometerData.floorsAscended) {
                                                       [jsonObject setObject:pedometerData.floorsAscended forKey:@"floorsup"];
                                                   }
                                                   if (pedometerData.floorsDescended) {
                                                       [jsonObject setObject:pedometerData.floorsDescended forKey:@"floorsdown"];
                                                   }
                                                   if (pedometerData.distance) {
                                                       [jsonObject setObject:pedometerData.distance forKey:@"distance"];
                                                   }
                                               } else {
                                                   [jsonObject setObject:@(-1) forKey:@"steps"];
                                               }
                                               
                                               [self.connectionOut sendData:[self jsonToData:jsonObject]
                                                                      topic:[[Settings theGeneralTopic] stringByAppendingString:@"/step"]
                                                                        qos:[Settings intForKey:@"qos_preference"]
                                                                     retain:NO];
                                           });
                                       }];
        
    } else if ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"] != NSOrderedAscending) {
        DDLogVerbose(@"isStepCountingAvailable %d", [CMStepCounter isStepCountingAvailable]);
        if (!self.stepCounter) {
            self.stepCounter = [[CMStepCounter alloc] init];
        }
        [self.stepCounter queryStepCountStartingFrom:fromDate
                                                  to:toDate
                                             toQueue:[[NSOperationQueue alloc] init]
                                         withHandler:^(NSInteger steps, NSError *error)
         {
             DDLogVerbose(@"StepCounter queryStepCountStartingFrom handler %ld %@ %@", (long)steps,
                          error.localizedDescription,
                          error.userInfo);
             dispatch_async(dispatch_get_main_queue(), ^{
                 
                 NSDictionary *jsonObject = @{
                                              @"_type": @"steps",
                                              @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                              @"from": @(floor([fromDate timeIntervalSince1970])),
                                              @"to": @(floor([toDate timeIntervalSince1970])),
                                              @"steps": error ? @(-1) : @(steps)
                                              };
                 
                 [self.connectionOut sendData:[self jsonToData:jsonObject]
                                        topic:[[Settings theGeneralTopic] stringByAppendingString:@"/step"]
                                          qos:[Settings intForKey:@"qos_preference"]
                                       retain:NO];
             });
         }];
    } else {
        NSDictionary *jsonObject = @{
                                     @"_type": @"steps",
                                     @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                     @"from": @(floor([fromDate timeIntervalSince1970])),
                                     @"to": @(floor([toDate timeIntervalSince1970])),
                                     @"steps": @(-1)
                                     };
        
        [self.connectionOut sendData:[self jsonToData:jsonObject]
                               topic:[[Settings theGeneralTopic] stringByAppendingString:@"/step"]
                                 qos:[Settings intForKey:@"qos_preference"]
                              retain:NO];
    }
}

#pragma actions

- (void)sendNow {
    DDLogVerbose(@"App sendNow");
    CLLocation *location = [LocationManager sharedInstance].location;
    [self publishLocation:location automatic:FALSE addon:@{@"t":@"u"}];
    [self.messaging newLocation:location.coordinate.latitude
                longitude:location.coordinate.longitude
                  context:[CoreData theManagedObjectContext]];
    
    
}

- (void)connectionOff {
    DDLogVerbose(@"App connectionOff");
    [self.connectionOut disconnect];
    [self.connectionIn disconnect];
}

- (void)syncProcessing {
    while ([self.inQueue unsignedLongValue] > 0) {
        DDLogVerbose(@"syncProcessing %lu", [self.inQueue unsignedLongValue]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    };
}

- (void)reconnect {
    DDLogVerbose(@"App reconnect");
    [self.connectionOut disconnect];
    [self.connectionIn disconnect];
    [self connect];
    [self sendNow];
}

- (void)publishLocation:(CLLocation *)location automatic:(BOOL)automatic addon:(NSDictionary *)addon {
    if (location && [Settings validIds]) {
        Location *newLocation = [Location locationWithTopic:[Settings theGeneralTopic]
                                                        tid:[Settings stringForKey:@"trackerid_preference"]
                                                  timestamp:location.timestamp
                                                 coordinate:location.coordinate
                                                   accuracy:location.horizontalAccuracy
                                                   altitude:location.altitude
                                           verticalaccuracy:location.verticalAccuracy
                                                      speed:(location.speed == -1) ? -1 : location.speed * 3600.0 / 1000.0
                                                     course:location.course
                                                  automatic:automatic
                                                     remark:nil
                                                     radius:0
                                                      share:NO
                                     inManagedObjectContext:[CoreData theManagedObjectContext]];
        
        NSData *data = [self encodeLocationData:newLocation type:@"location" addon:addon];
        
        [self.connectionOut sendData:data
                               topic:[Settings theGeneralTopic]
                                 qos:[Settings intForKey:@"qos_preference"]
                              retain:[Settings boolForKey:@"retain_preference"]];
        
        [self limitLocationsWith:newLocation.belongsTo
                       toMaximum:[Settings intForKey:@"positions_preference"]
          inManagedObjectContext:[CoreData theManagedObjectContext]];
        
        [CoreData saveContext];
        [self.connectionIn connectToLast];
        [self share];
    } else {
        DDLogVerbose(@"publishLocation (null) ignored");
    }
}

- (void)sendEmpty:(NSString *)topic {
    [self.connectionOut sendData:nil
                           topic:topic
                             qos:[Settings intForKey:@"qos_preference"]
                          retain:YES];
}

- (void)requestLocationFromFriend:(Friend *)friend {
    NSDictionary *jsonObject = @{
                                 @"_type": @"cmd",
                                 @"action": @"reportLocation"
                                 };
    
    [self.connectionOut sendData:[self jsonToData:jsonObject]
                           topic:[friend.topic stringByAppendingString:@"/cmd"]
                             qos:[Settings intForKey:@"qos_preference"]
                          retain:NO];
}

- (void)sendWayPoint:(Location *)location {
    if ([Settings validIds]) {
        NSMutableDictionary *addon = [[NSMutableDictionary alloc]init];
        
        if (location.remark) {
            [addon setValue:location.remark forKey:@"desc"];
        }
        
        NSData *data = [self encodeLocationData:location
                                           type:@"waypoint" addon:addon];
        
        [self.connectionOut sendData:data
                               topic:[[Settings theGeneralTopic] stringByAppendingString:@"/waypoint"]
                                 qos:[Settings intForKey:@"qos_preference"]
                              retain:NO];
        
        [CoreData saveContext];
    }
}

- (void)limitLocationsWith:(Friend *)friend toMaximum:(NSInteger)max inManagedObjectContext:(NSManagedObjectContext *)context {
    NSArray *allLocations = [Location allAutomaticLocationsWithFriend:friend
                                               inManagedObjectContext:context];
    
    for (NSInteger i = [allLocations count]; i > max; i--) {
        Location *location = allLocations[i - 1];
        [context deleteObject:location];
    }
}

#pragma internal helpers

- (void)notification:(NSString *)message userInfo:(NSDictionary *)userInfo {
    DDLogVerbose(@"App notification %@ userinfo %@", message, userInfo);
    
    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.alertBody = message;
    notification.alertLaunchImage = @"itunesArtwork.png";
    notification.userInfo = userInfo;
    notification.fireDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [[UIApplication sharedApplication] scheduleLocalNotification:notification];
    
    if (notification.userInfo) {
        if ([notification.userInfo[@"notify"] isEqualToString:@"friend"]) {
            [AlertView alert:@"Friend Notification" message:notification.alertBody dismissAfter:2.0];
        }
        if ([notification.userInfo[@"notify"] isEqualToString:@"msg"]) {
            [AlertView alert:@"Message" message:notification.alertBody dismissAfter:2.0];
        }
    }
}

- (void)connect {
    [self.connectionOut connectTo:[Settings stringForKey:@"host_preference"]
                             port:[Settings intForKey:@"port_preference"]
                              tls:[Settings boolForKey:@"tls_preference"]
                        keepalive:[Settings intForKey:@"keepalive_preference"]
                            clean:[Settings intForKey:@"clean_preference"]
                             auth:[Settings theMqttAuth]
                             user:[Settings theMqttUser]
                             pass:[Settings theMqttPass]
                        willTopic:[Settings theWillTopic]
                             will:[self jsonToData:@{
                                                     @"tst": [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]],
                                                     @"_type": @"lwt"}]
                          willQos:[Settings intForKey:@"willqos_preference"]
                   willRetainFlag:[Settings boolForKey:@"willretain_preference"]
                     withClientId:[NSString stringWithFormat:@"%@-o", [Settings theClientId]]];
    
    MQTTQosLevel subscriptionQos =[Settings intForKey:@"subscriptionqos_preference"];
    NSArray *subscriptions = [[Settings theSubscriptions] componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
    
    self.connectionIn.subscriptions = subscriptions;
    self.connectionIn.subscriptionQos = subscriptionQos;
    
    [self.connectionIn connectTo:[Settings stringForKey:@"host_preference"]
                            port:[Settings intForKey:@"port_preference"]
                             tls:[Settings boolForKey:@"tls_preference"]
                       keepalive:[Settings intForKey:@"keepalive_preference"]
                           clean:[Settings intForKey:@"clean_preference"]
                            auth:[Settings theMqttAuth]
                            user:[Settings theMqttUser]
                            pass:[Settings theMqttPass]
                       willTopic:nil
                            will:nil
                         willQos:MQTTQosLevelAtMostOnce
                  willRetainFlag:NO
                    withClientId:[NSString stringWithFormat:@"%@-i", [Settings theClientId]]];
}

- (NSData *)jsonToData:(NSDictionary *)jsonObject {
    NSData *data;
    
    if ([NSJSONSerialization isValidJSONObject:jsonObject]) {
        NSError *error;
        data = [NSJSONSerialization dataWithJSONObject:jsonObject options:0 /* not pretty printed */ error:&error];
        if (!data) {
            NSString *message = [NSString stringWithFormat:@"%@ %@ %@",
                                 error.localizedDescription,
                                 error.userInfo,
                                 [jsonObject description]];
            [AlertView alert:@"dataWithJSONObject" message:message];
        }
    } else {
        NSString *message = [NSString stringWithFormat:@"%@", [jsonObject description]];
        [AlertView alert:@"isValidJSONObject" message:message];
    }
    return data;
}


- (NSData *)encodeLocationData:(Location *)location type:(NSString *)type addon:(NSDictionary *)addon {
    NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
    [jsonObject setValue:[NSString stringWithFormat:@"%@", type] forKey:@"_type"];
    
    [jsonObject setValue:@(location.coordinate.latitude) forKey:@"lat"];
    [jsonObject setValue:@(location.coordinate.longitude) forKey:@"lon"];
    [jsonObject setValue:@((int)[location.timestamp timeIntervalSince1970]) forKey:@"tst"];
    
    double acc = [location.accuracy doubleValue];
    if (acc > 0) {
        [jsonObject setValue:@(acc) forKey:@"acc"];
    }
    
    if ([Settings boolForKey:@"extendeddata_preference"]) {
        int alt = [location.altitude intValue];
        [jsonObject setValue:@(alt) forKey:@"alt"];
        
        int vac = [location.verticalaccuracy intValue];
        [jsonObject setValue:@(vac) forKey:@"vac"];
        
        int vel = [location.speed intValue];
        [jsonObject setValue:@(vel) forKey:@"vel"];
        
        int cog = [location.course intValue];
        [jsonObject setValue:@(cog) forKey:@"cog"];
        
        CMAltitudeData *altitude = [LocationManager sharedInstance].altitude;
        if (altitude) {
            [jsonObject setValue:altitude.pressure forKey:@"p"];
        }
    }
    
    [jsonObject setValue:[location.belongsTo getEffectiveTid] forKeyPath:@"tid"];
    
    double rad = [location.regionradius doubleValue];
    if (rad > 0) {
        [jsonObject setValue:@((int)rad) forKey:@"rad"];
    }
    
    if (addon) {
        [jsonObject addEntriesFromDictionary:addon];
    }
    
    if ([type isEqualToString:@"location"]) {
        int batteryLevel = [UIDevice currentDevice].batteryLevel != -1 ? [UIDevice currentDevice].batteryLevel * 100 : -1;
        [jsonObject setValue:@(batteryLevel) forKey:@"batt"];
    }
    
    return [self jsonToData:jsonObject];
}

- (void)share {
    if ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"] != NSOrderedAscending) {
        NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.org.owntracks.Owntracks"];
        NSArray *friends = [Friend allFriendsInManagedObjectContext:[CoreData theManagedObjectContext]];
        NSMutableDictionary *sharedFriends = [[NSMutableDictionary alloc] init];
        CLLocation *myCLLocation = [LocationManager sharedInstance].location;
        
        for (Friend *friend in friends) {
            NSString *name = [friend name];
            NSData *image = [friend image];
            
            if (!image) {
                image = UIImageJPEGRepresentation([UIImage imageNamed:@"Friend"], 0.5);
            }
            
            Location *friendsLocation = [friend newestLocation];
            if (friendsLocation) {
                CLLocation *friendsCLLocation = [[CLLocation alloc]
                                                 initWithLatitude:[friendsLocation.latitude doubleValue]
                                                 longitude:[friendsLocation.longitude doubleValue]];
                NSNumber *distance = @([myCLLocation distanceFromLocation:friendsCLLocation]);
                if (name) {
                    if (friendsLocation.timestamp &&
                        friendsLocation.latitude &&
                        friendsLocation.longitude &&
                        friend.topic &&
                        image) {
                        NSMutableDictionary *aFriend = [[NSMutableDictionary alloc] init];
                        [aFriend setObject:image forKey:@"image"];
                        [aFriend setObject:distance forKey:@"distance"];
                        [aFriend setObject:friendsLocation.longitude forKey:@"longitude"];
                        [aFriend setObject:friendsLocation.latitude forKey:@"latitude"];
                        [aFriend setObject:friendsLocation.timestamp forKey:@"timestamp"];
                        [aFriend setObject:friend.topic forKey:@"topic"];
                        [sharedFriends setObject:aFriend forKey:name];
                    } else {
                        DDLogVerbose(@"friend or location incomplete");
                    }
                }
            }
        }
        DDLogVerbose(@"sharedFriends %@", [sharedFriends allKeys]);
        [shared setValue:sharedFriends forKey:@"sharedFriends"];
    }
}


@end
