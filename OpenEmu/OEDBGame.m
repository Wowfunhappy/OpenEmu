/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEDBGame.h"

#import "OELibraryDatabase.h"

#import "OEDBSystem.h"
#import "OEDBRom.h"
#import "OEDBImage.h"

#import "OEGameInfoHelper.h"

#import "NSFileManager+OEHashingAdditions.h"
#import "NSArray+OEAdditions.h"

NSString *const OEPasteboardTypeGame = @"org.openemu.game";
NSString *const OEDisplayGameTitle = @"displayGameTitle";

NSString *const OEGameArtworkFormatKey = @"artworkFormat";
NSString *const OEGameArtworkPropertiesKey = @"artworkProperties";

@implementation OEDBGame
@dynamic name, gameTitle, rating, gameDescription, importDate, lastInfoSync, status, displayName;
@dynamic boxImage, system, roms, genres, collections, credits;

+ (void)initialize
{
     if (self == [OEDBGame class])
     {
         [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                                                                   OEGameArtworkFormatKey : @(NSJPEGFileType),
                                                                   OEGameArtworkPropertiesKey : @{
                                                                           NSImageCompressionFactor : @(0.9)
                                                                           }
                                                                   }];
     }
}

#pragma mark - Creating and Obtaining OEDBGames

+ (id)createGameWithName:(NSString *)name andSystem:(OEDBSystem *)system inDatabase:(OELibraryDatabase *)database
{
    NSManagedObjectContext *context = [database mainThreadContext];

    __block OEDBGame *game = nil;
    [context performBlockAndWait:^{
        NSEntityDescription *description = [NSEntityDescription entityForName:@"Game" inManagedObjectContext:context];
        game = [[OEDBGame alloc] initWithEntity:description insertIntoManagedObjectContext:context];

        [game setName:name];
        [game setImportDate:[NSDate date]];
        [game setSystem:system];
    }];
    
    return game;
}

// returns the game from the default database that represents the file at url
+ (id)gameWithURL:(NSURL *)url error:(NSError *__autoreleasing*)outError
{
    return [self gameWithURL:url inDatabase:[OELibraryDatabase defaultDatabase] error:outError];
}

// returns the game from the specified database that represents the file at url
+ (id)gameWithURL:(NSURL *)url inDatabase:(OELibraryDatabase *)database error:(NSError *__autoreleasing*)outError
{
    if(url == nil)
    {
        // TODO: create error saying that url is nil
        return nil;
    }
    
    NSError __autoreleasing *nilerr;
    if(outError == NULL) outError = &nilerr;

    url = [url URLByStandardizingPath];
    BOOL urlReachable = [url checkResourceIsReachableAndReturnError:outError];

    // TODO: FIX
    OEDBGame *game = nil;
    NSManagedObjectContext *context = [database mainThreadContext];
    OEDBRom *rom = [OEDBRom romWithURL:url inContext:context error:outError];
    if(rom != nil)
    {
        game = [rom game];
    }
    
    NSString *md5 = nil, *crc = nil;
    NSFileManager *defaultFileManager = [NSFileManager defaultManager];
    if(game == nil && urlReachable)
    {
        [defaultFileManager hashFileAtURL:url md5:&md5 crc32:&crc error:outError];
        OEDBRom *rom = [OEDBRom romWithMD5HashString:md5 inContext:context error:outError];
        
        //Wowfunhappy: We definitely don't care what the rom URL used to be! We care what it is _now_! It might have been moved or renamed.
        //No idea if OpenEmu used to have logic for this which I inadvertently ripped out...
        //[rom setURL: url];
        
        if(!rom) rom = [OEDBRom romWithCRC32HashString:crc inContext:context error:outError];
        if(rom) game = [rom game];
        
        //Wowfunhappy: See above—now we also need to reset the game title, as it might have been renamed.
        //NSString *gameTitleWithSuffix = [url lastPathComponent];
        //NSString *gameTitleWithoutSuffix = [gameTitleWithSuffix stringByDeletingPathExtension];
        //[game setName:gameTitleWithoutSuffix];
        
        
    }
    
    if(!urlReachable)
        [game setStatus:[NSNumber numberWithInt:OEDBGameStatusAlert]];

    return game;
}


#pragma mark - Cover Art Database Sync / Info Lookup
- (void)requestCoverDownload
{
    if([[self status] isEqualTo:@(OEDBGameStatusAlert)] || [[self status] isEqualTo:@(OEDBGameStatusOK)])
    {
        [self setStatus:[NSNumber numberWithInt:OEDBGameStatusProcessing]];
        [self save];
        //[[self libraryDatabase] startOpenVGDBSync];
    }
}

- (void)cancelCoverDownload
{
    if([[self status] isEqualTo:@(OEDBGameStatusProcessing)])
    {
        [self setStatus:[NSNumber numberWithInt:OEDBGameStatusOK]];
        [self save];
    }
}

- (void)requestInfoSync
{
    if([[self status] isEqualTo:@(OEDBGameStatusAlert)] || [[self status] isEqualTo:@(OEDBGameStatusOK)])
    {
        [self setStatus:@(OEDBGameStatusProcessing)];
        [self save];
        //[[self libraryDatabase] startOpenVGDBSync];
    }
}

#pragma mark - Accessors
- (NSDate *)lastPlayed
{
    NSArray *roms = [[self roms] allObjects];
    
    NSArray *sortedByLastPlayed =
    [roms sortedArrayUsingComparator:
     ^ NSComparisonResult (id obj1, id obj2)
     {
         return [[obj1 lastPlayed] compare:[obj2 lastPlayed]];
     }];
    
    return [[sortedByLastPlayed lastObject] lastPlayed];
}

- (OEDBSaveState *)autosaveForLastPlayedRom
{
    NSArray *roms = [[self roms] allObjects];
    
    NSArray *sortedByLastPlayed =
    [roms sortedArrayUsingComparator:
     ^ NSComparisonResult (id obj1, id obj2)
     {
         return [[obj1 lastPlayed] compare:[obj2 lastPlayed]];
     }];
	
    return [[sortedByLastPlayed lastObject] autosaveState];
}

- (NSNumber *)saveStateCount
{
    NSUInteger count = 0;
    for(OEDBRom *rom in [self roms]) count += [rom saveStateCount];
    return @(count);
}

- (OEDBRom *)defaultROM
{
    NSSet *roms = [self roms];
    // TODO: if multiple roms are available we should select one based on version/revision and language
    
    return [roms anyObject];
}

- (NSNumber *)playCount
{
    NSUInteger count = 0;
    for(OEDBRom *rom in [self roms]) count += [[rom playCount] unsignedIntegerValue];
    return @(count);
}

- (NSNumber *)playTime
{
    NSTimeInterval time = 0;
    for(OEDBRom *rom in [self roms]) time += [[rom playTime] doubleValue];
    return @(time);
}

- (BOOL)filesAvailable
{
    __block BOOL result = YES;
    [[self roms] enumerateObjectsUsingBlock:^(OEDBRom *rom, BOOL *stop) {
        if(![rom filesAvailable])
        {
            result = NO;
            *stop = YES;
        }
    }];

    if([[self status] isEqualTo:@(OEDBGameStatusDownloading)] || [[self status] isEqualTo:@(OEDBGameStatusProcessing)])
       return result;

    if(!result)
       [self setStatus:[NSNumber numberWithInt:OEDBGameStatusAlert]];
    else if([[self status] intValue] == OEDBGameStatusAlert)
        [self setStatus:[NSNumber numberWithInt:OEDBGameStatusOK]];
    
    return result;
}

#pragma mark -
- (void)setBoxImageByImage:(NSImage *)img
{
    NSDictionary *dictionary = [OEDBImage prepareImageWithNSImage:img];
    NSManagedObjectContext *context = [self managedObjectContext];
    [context performBlockAndWait:^{
        OEDBImage *currentImage = [self boxImage];
        if(currentImage) [context deleteObject:currentImage];

        OEDBImage *newImage = [OEDBImage createImageWithDictionary:dictionary];
        if(newImage) [self setBoxImage:newImage];
        else [context deleteObject:newImage];
    }];
}

- (void)setBoxImageByURL:(NSURL *)url
{
    url = [url URLByStandardizingPath];
    NSString      *urlString = [url absoluteString];

    NSDictionary *dictionary = [OEDBImage prepareImageWithURLString:urlString];
    NSManagedObjectContext *context = [self managedObjectContext];
    [context performBlockAndWait:^{
        OEDBImage *currentImage = [self boxImage];
        if(currentImage) [context deleteObject:currentImage];

        OEDBImage *newImage = [OEDBImage createImageWithDictionary:dictionary];
        if(newImage) [self setBoxImage:newImage];
        else [context deleteObject:newImage];
    }];
}

#pragma mark - Core Data utilities
- (void)awakeFromFetch
{
    if([[self status] isEqualTo:@(OEDBGameStatusDownloading)])
    {
        [self setStatus:@(OEDBGameStatusOK)];
    }
}

- (void)deleteByMovingFile:(BOOL)moveToTrash keepSaveStates:(BOOL)statesFlag
{
    NSMutableSet *mutableRoms = [self mutableRoms];
    while ([mutableRoms count])
    {
        OEDBRom *aRom = [mutableRoms anyObject];
        [aRom deleteByMovingFile:moveToTrash keepSaveStates:statesFlag];
        [mutableRoms removeObject:aRom];
    }
    [self setRoms:[NSSet set]];
    [[self managedObjectContext] deleteObject:self];
}

+ (NSString *)entityName
{
    return @"Game";
}

+ (NSEntityDescription *)entityDescriptionInContext:(NSManagedObjectContext *)context
{
    return [NSEntityDescription entityForName:[self entityName] inManagedObjectContext:context];
}

#pragma mark - NSPasteboardWriting
// TODO: fix pasteboard writing
- (NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return [NSArray arrayWithObjects:(NSString *)kPasteboardTypeFileURLPromise, OEPasteboardTypeGame, /* NSPasteboardTypeTIFF,*/ nil];
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard
{
    if(type ==(NSString *)kPasteboardTypeFileURLPromise)
        return NSPasteboardWritingPromised;
    
    return 0;
}

- (id)pasteboardPropertyListForType:(NSString *)type
{
    if(type == (NSString *)kPasteboardTypeFileURLPromise)
    {
        NSSet *roms = [self roms];
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[roms count]];
        for(OEDBRom *aRom in roms)
        {
            NSString *urlString = [[aRom URL] absoluteString];
            [paths addObject:urlString];
        }
        return paths;
    } 
    else if(type == OEPasteboardTypeGame)
    {
        return [[self permanentIDURI] absoluteString];
    }
    
    // TODO: return appropriate obj
    DLog(@"Unkown type %@", type);
    return nil;
}

#pragma mark - NSPasteboardReading

- (id)initWithPasteboardPropertyList:(id)propertyList ofType:(NSString *)type
{
    if(type == OEPasteboardTypeGame)
    {
        OELibraryDatabase *database = [OELibraryDatabase defaultDatabase];
        NSManagedObjectContext *context = [database mainThreadContext];
        NSURL    *uri  = [NSURL URLWithString:propertyList];
        return (self = [OEDBGame objectWithURI:uri inContext:context]);
    } 
    return nil;
}

+ (NSArray *)readableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return [NSArray arrayWithObjects:OEPasteboardTypeGame, nil];
}

+ (NSPasteboardReadingOptions)readingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard
{
    return NSPasteboardReadingAsString;
}

#pragma mark - Data Model Relationships

- (NSMutableSet *)mutableRoms
{
    return [self mutableSetValueForKey:@"roms"];
}

- (NSMutableSet *)mutableGenres
{
    return [self mutableSetValueForKey:@"genres"];
}
- (NSMutableSet *)mutableCollections
{
    return [self mutableSetValueForKeyPath:@"collections"];
}
- (NSMutableSet *)mutableCredits
{
    return [self mutableSetValueForKeyPath:@"credits"];
}

- (NSString *)displayName
{
    if([[NSUserDefaults standardUserDefaults] boolForKey:OEDisplayGameTitle])
        return ([self gameTitle] != nil ? [self gameTitle] : [self name]);
    else
        return [self name];
}

- (void)setDisplayName:(NSString *)displayName
{
    if([[NSUserDefaults standardUserDefaults] boolForKey:OEDisplayGameTitle])
        ([self gameTitle] != nil ? [self setGameTitle:displayName] : [self setName:displayName]);
    else
        [self setName:displayName];
}

- (NSString *)cleanDisplayName
{
    NSString *displayName = [self displayName];
    NSDictionary *articlesDictionary = @{
                                 @"A "   : @"2",
                                 @"An "  : @"3",
                                 @"Das " : @"4",
                                 @"Der " : @"4",
                                 //@"Die " : @"4", Biased since some English titles start with Die
                                 @"Gli " : @"4",
                                 @"L'"   : @"2",
                                 @"La "  : @"3",
                                 @"Las " : @"4",
                                 @"Le "  : @"3",
                                 @"Les " : @"4",
                                 @"Los " : @"4",
                                 @"The " : @"4",
                                 @"Un "  : @"3",
                                 };
    
    for (id key in articlesDictionary) {
        if([displayName hasPrefix:key])
        {
            return [displayName substringFromIndex:[articlesDictionary[key] integerValue]];
        }
        
    }
    
    return  displayName;
}

#pragma mark - Debug

- (void)dump
{
    [self dumpWithPrefix:@"---"];
}

- (void)dumpWithPrefix:(NSString *)prefix
{
    NSString *subPrefix = [prefix stringByAppendingString:@"-----"];
    NSLog(@"%@ Beginning of game dump", prefix);

    NSLog(@"%@ Game name is %@", prefix, [self name]);
    NSLog(@"%@ title is %@", prefix, [self gameTitle]);
    NSLog(@"%@ rating is %@", prefix, [self rating]);
    NSLog(@"%@ description is %@", prefix, [self gameDescription]);
    NSLog(@"%@ import date is %@", prefix, [self importDate]);
    NSLog(@"%@ last info sync is %@", prefix, [self lastInfoSync]);
    NSLog(@"%@ last played is %@", prefix, [self lastPlayed]);
    NSLog(@"%@ status is %@", prefix, [self status]);

    NSLog(@"%@ Number of ROMs for this game is %lu", prefix, (unsigned long)[[self roms] count]);

    for(id rom in [self roms])
    {
        if([rom respondsToSelector:@selector(dumpWithPrefix:)]) [rom dumpWithPrefix:subPrefix];
        else NSLog(@"%@ ROM is %@", subPrefix, rom);
    }

    NSLog(@"%@ End of game dump\n\n", prefix);
}

@end
