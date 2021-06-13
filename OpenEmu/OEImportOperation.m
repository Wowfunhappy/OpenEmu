/*
 Copyright (c) 2012, OpenEmu Team

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

#import "OEImportOperation.h"
#import "OESystemPlugin.h"
#import "OECorePlugin.h"

#import "OEROMImporter.h"
#import <MagicKit/MagicKit.h>
#import <XADMaster/XADArchive.h>

#import "NSFileManager+OEHashingAdditions.h"
#import "NSURL+OELibraryAdditions.h"

#import "OELibraryDatabase.h"
#import "OEDBGame.h"
#import "OEDBRom.h"
#import "OEDBCollection.h"

NSString * const OEImportManualSystems = @"OEImportManualSystems";

@interface OEImportOperation ()
- (void)OE_performImportStepCheckDirectory;
- (void)OE_performImportStepCheckArchiveFile;
- (void)OE_performImportStepHash;
- (void)OE_performImportStepCheckHash;
- (void)OE_performImportStepDetermineSystem;
- (void)OE_performImportStepOrganize;
- (void)OE_performImportStepOrganizeAdditionalFiles;
- (void)OE_performImportStepCreateCoreDataObjects;
@end

@interface OEImportOperation ()
@property (readonly, nonatomic) BOOL shouldExit;

@property (strong, readwrite) NSString  *fileName;
@property (strong, readwrite) NSURL     *extractedFileURL;
@property (readwrite)         NSInteger  archiveFileIndex;

@property (strong, readwrite) NSString *md5Hash;
@property (strong, readwrite) NSString *crcHash;

@property (strong, readwrite) OEDBRom *rom;
@end

@implementation OEImportOperation
@synthesize checked;

#pragma mark - Creating Import Operations
+ (instancetype)operationWithURL:(NSURL*)url inImporter:(OEROMImporter*)importer
{
    NSError *error = nil;
    if(![url checkResourceIsReachableAndReturnError:&error])
    {
        IMPORTDLog(@"Could not reach url at %@", url);
        IMPORTDLog(@"%@", error);
        return nil;
    }

    // Ignore hidden or package files
    NSDictionary *resourceValues = [url resourceValuesForKeys:@[ NSURLIsPackageKey, NSURLIsHiddenKey ] error:nil];
    if([[resourceValues objectForKey:NSURLIsHiddenKey] boolValue] || [[resourceValues objectForKey:NSURLIsPackageKey] boolValue])
    {
        IMPORTDLog(@"Item is hidden file or package directory at %@", url);
        return nil;
    }

    // Check for .cg filters and copy them directly (not going through importer queue)
    if([self OE_isFilterAtURL:url])
        return nil;

    // Ignore text files that are .md
    if([self OE_isTextFileAtURL:url])
        return nil;

    if([self isBiosFileAtURL:url])
        return nil;

    if([self OE_isInvalidExtensionAtURL:url])
        return nil;

    OEImportOperation *item = [[OEImportOperation alloc] init];
    [item setImporter:importer];
    [item setURL:url];
    [item setSourceURL:url];

    return item;
}

+ (BOOL)OE_isFilterAtURL:(NSURL*)url
{
    NSString *pathExtension = [[url pathExtension] lowercaseString];
    if([pathExtension isEqualToString:@"cg"])
    {
        IMPORTDLog(@"File seems to be a filter at %@", url);

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError       *error       = nil;
        NSString      *cgFilename  = [url lastPathComponent];
        NSString      *filtersPath = [NSString pathWithComponents:@[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject], @"OpenEmu", @"Filters"]];
        NSString      *destination = [filtersPath stringByAppendingPathComponent:cgFilename];


        if(![fileManager createDirectoryAtURL:[NSURL fileURLWithPath:filtersPath] withIntermediateDirectories:YES attributes:nil error:&error])
        {
            IMPORTDLog(@"Could not create directory before copying filter at %@", url);
            IMPORTDLog(@"%@", error);
            error = nil;
        }

        if(![fileManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error])
        {
            IMPORTDLog(@"Could not copy filter %@ to %@", url, destination);
            IMPORTDLog(@"%@", error);
        }

        return YES;
    }
    return NO;
}

+ (BOOL)OE_isTextFileAtURL:(NSURL*)url;
{
    NSString *pathExtension = [[url pathExtension] lowercaseString];
    if([pathExtension isEqualToString:@"md"] && [[[GEMagicKit magicForFileAtURL:url] uniformTypeHierarchy] containsObject:(id)kUTTypeText])
    {
        IMPORTDLog(@"Text file found at %@", url);
        return YES;
    }
    return NO;
}

+ (BOOL)isBiosFileAtURL:(NSURL*)url
{
    NSString *md5 = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString      *biosPath = [NSString pathWithComponents:@[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject], @"OpenEmu", @"BIOS"]];

    // Copy known BIOS / System Files to BIOS folder
    for(id validFile in [OECorePlugin requiredFiles])
    {
        NSString *biosSystemFileName = [validFile valueForKey:@"Name"];
        NSString *biosSystemFileMD5  = [validFile valueForKey:@"MD5"];
        NSString *biosFilename       = [url lastPathComponent];
        NSError  *error              = nil;

        if([biosFilename caseInsensitiveCompare:biosSystemFileName] == NSOrderedSame)
        {
            IMPORTDLog(@"File seems to be a bios at %@", url);

            NSString      *destination = [biosPath stringByAppendingPathComponent:biosFilename];

            if(!md5 && ![fileManager hashFileAtURL:url md5:&md5 crc32:nil error:&error])
            {
                IMPORTDLog(@"Could not hash bios file at %@", url);
                IMPORTDLog(@"%@", error);
            }
            
            if(![md5 caseInsensitiveCompare:biosSystemFileMD5] == NSOrderedSame)
            {
                IMPORTDLog(@"Could not match hashes of bios file %@ with db %@", md5, biosSystemFileMD5);
                IMPORTDLog(@"%@", error);
                return NO;
            }

            if(![fileManager createDirectoryAtURL:[NSURL fileURLWithPath:biosPath] withIntermediateDirectories:YES attributes:nil error:&error])
            {
                IMPORTDLog(@"Could not create directory before copying bios at %@", url);
                IMPORTDLog(@"%@", error);
                error = nil;
            }

            if(![fileManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error])
            {
                DLog(@"Could not copy bios file %@ to %@", url, destination);
                IMPORTDLog(@"%@", error);
            }

            return YES;
        }
    }
    return NO;
}

+ (BOOL)OE_isInvalidExtensionAtURL:(NSURL *)url
{
    NSString *pathExtension = [[url pathExtension] lowercaseString];

    // Ignore unsupported file extensions
    NSMutableSet *validExtensions = [NSMutableSet setWithArray:[OESystemPlugin supportedTypeExtensions]];

    // TODO:
    // The Archived Game document type lists all supported archive extensions, e.g. zip
    NSDictionary *bundleInfo      = [[NSBundle mainBundle] infoDictionary];
    NSArray      *docTypes        = [bundleInfo objectForKey:@"CFBundleDocumentTypes"];
    for(NSDictionary *docType in docTypes)
    {
        if([[docType objectForKey:@"CFBundleTypeName"] isEqualToString:@"Archived Game"])
        {
            [validExtensions addObjectsFromArray:[docType objectForKey:@"CFBundleTypeExtensions"]];
            break;
        }
    }

    if(![url isDirectory])
    {
        if([pathExtension length] > 0 && ![validExtensions containsObject:pathExtension])
        {
            IMPORTDLog(@"File has unsupported extension (%@) at %@", pathExtension, url);
            return YES;
        }
    }

    return NO;
}

#pragma mark - NSCoding Protocol
- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _shouldExit = NO;
        _archiveFileIndex = NSNotFound;
        _exploreArchives  = YES;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [self init];
    if (self)
    {
        [self setURL:[decoder decodeObjectForKey:@"URL"]];
        [self setSourceURL:[decoder decodeObjectForKey:@"sourceURL"]];
        [self setExitStatus:OEImportExitNone];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder
{
    [encoder encodeObject:[self URL] forKey:@"URL"];
    [encoder encodeObject:[self sourceURL] forKey:@"sourceURL"];
}

- (id)copyWithZone:(NSZone *)zone
{
    OEImportOperation *copy = [[OEImportOperation allocWithZone:zone] init];
    [copy setExitStatus:OEImportExitNone];
    [copy setError:nil];

    [copy setExploreArchives:[self exploreArchives]];
    [copy setURL:[self URL]];
    [copy setSourceURL:[self sourceURL]];
    [copy setCollectionID:[self collectionID]];
    [copy setRom:[self rom]];

    [copy setSystemIdentifiers:[self systemIdentifiers]];
    [copy setCompletionHandler:[self completionHandler]];
    [copy setImporter:[self importer]];

    [copy setChecked:[self checked]];

    [copy setFileName:[self fileName]];
    [copy setExtractedFileURL:[self extractedFileURL]];
    [copy setArchiveFileIndex:[self archiveFileIndex]];
    [copy setMd5Hash:[self md5Hash]];
    [copy setCrcHash:[self crcHash]];

    return copy;
}
#pragma mark -
- (void)exitWithStatus:(OEImportExitStatus)status error:(NSError*)error
{
    NSManagedObjectContext *context = [[self importer] context];

    if(status == OEImportExitSuccess)
    {
        OEDBRom *rom = [self rom];
        if(rom != nil)
        {
            if([self collectionID] != nil && [rom game] != nil)
            {
                OEDBCollection *collection = [OEDBCollection objectWithID:[self collectionID] inContext:context];
                if(collection != nil && [collection isDeleted] == NO)
                {
                    [[[rom game] mutableCollections] addObject:collection];
                }
            }

            // start sync thread
            if([[[rom game] status] intValue] == OEDBGameStatusProcessing)
            {
                OELibraryDatabase *database = [[self importer] database];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    [database startOpenVGDBSync];
                });
            }
        }
    }

    if(status != OEImportExitErrorFatal)
    {
        [context save:nil];
        NSManagedObjectContext *parentContext = [context parentContext];
        [parentContext performBlock:^{
            [parentContext save:nil];
        }];
    }

    [[NSFileManager defaultManager] removeItemAtURL:[self extractedFileURL] error:nil];

    _shouldExit = YES;
    [self setError:error];
    [self setExitStatus:status];
}

- (BOOL)shouldExit
{
    return _shouldExit || [self isCancelled];
}
@synthesize shouldExit=_shouldExit;

- (NSManagedObjectID*)romObjectID
{
    return [[self rom] permanentID];
}

#pragma mark - NSOperation Overrides
- (void)main
{
    @autoreleasepool {
        [[[self importer] context] performBlockAndWait:^{
            if([self shouldExit]) return;
            
            [self OE_performImportStepCheckDirectory];
            if([self shouldExit]) return;
            
            [self OE_performImportStepCheckArchiveFile];
            if([self shouldExit]) return;
            
            [self OE_performImportStepDetermineSystem];
            if([self shouldExit]) return;
            
            [self OE_performImportStepHash];
            if([self shouldExit]) return;
            
            [self OE_performImportStepCheckHash];
            if([self shouldExit]) return;
            
            [self OE_performImportStepCreateCoreDataObjects];
        }];
        
    }
}
#pragma mark - Importing
- (void)OE_performImportStepCheckDirectory
{
    // Check if file at URL is a directory
    // if so, add new items for each item in the directory
    NSURL *url = [self URL];
    if([url isDirectory])
    {
        NSArray *propertyKeys = @[NSURLIsPackageKey, NSURLIsHiddenKey];
        NSUInteger    options = NSDirectoryEnumerationSkipsSubdirectoryDescendants|NSDirectoryEnumerationSkipsPackageDescendants|NSDirectoryEnumerationSkipsHiddenFiles;

        NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:url includingPropertiesForKeys:propertyKeys options:options errorHandler:NULL];

        NSURL *subURL = nil;
        while([self isCancelled] == NO && (subURL = [directoryEnumerator nextObject]))
        {
            OEROMImporter    *importer = [self importer];
            OEImportOperation *subItem = [OEImportOperation operationWithURL:subURL inImporter:importer];
            if(subItem)
            {
                [subItem setCompletionHandler:[self completionHandler]];
                [subItem setCollectionID:[self collectionID]];
                [importer addOperation:subItem];
            }
        }

        [self exitWithStatus:OEImportExitSuccess error:nil];
    }
}
- (void)OE_performImportStepCheckArchiveFile
{
    if([self exploreArchives] == NO) return;
    IMPORTDLog();
    NSURL *url = [self URL];
    NSString *path = [url path];
    NSString *extension = [[path pathExtension] lowercaseString];

    // nds and some isos might be recognized as compressed archives by XADArchive
    // but we don't ever want to extract anything from those files
    if([extension isEqualToString:@"nds"] || [extension isEqualToString:@"iso"])
        return;

    XADArchive *archive = nil;
    @try
    {
        archive = [XADArchive archiveForFile:path];
    }
    @catch(NSException *e)
    {
        archive = nil;
    }

    if(archive != nil)
    {
        NSString    *formatName = [archive formatName];

        // XADArchive file detection is not exactly the best
        // ignore some formats
        if ([formatName isEqualToString:@"MacBinary"])
            return;
        
        if( [formatName isEqualToString:@"LZMA_Alone"])
            return;
        
        // disable multi-rom archives
        if([archive numberOfEntries] > 1)
            return;
        
        for(int i=0; i<[archive numberOfEntries]; i++)
        {
            if(![archive entryHasSize:i] || [archive entryIsEncrypted:i] || [archive entryIsDirectory:i] || [archive entryIsArchive:i])
            {
                IMPORTDLog(@"Entry %d is either empty, or a directory or encrypted or iteself an archive", i);
                continue;
            }

            NSString *folder = temporaryDirectoryForDecompressionOfPath(path);
            NSString *name   = [archive nameOfEntry:i];
            if ([[name pathExtension] length] == 0 && [[path pathExtension] length] > 0) {
                // this won't do. Re-add the archive's extension in case it's .smc or the like
                name = [name stringByAppendingPathExtension:[path pathExtension]];
            }

            [self setFileName:name];
            NSString *extractionPath = [folder stringByAppendingPathComponent:name];

            BOOL isdir;
            NSURL *tmpURL = [NSURL fileURLWithPath:extractionPath];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:extractionPath isDirectory:&isdir]) {
                @try
                {
                    [archive _extractEntry:i as:extractionPath deferDirectories:YES dataFork:YES resourceFork:NO];
                }
                @catch (NSException *exception) {
                    NSLog(@"exception handeled");
                }
                
                // exception is caught but handler does not execute, so check if extraction worked
                NSNumber *fileSize = [tmpURL fileSize];
                if([fileSize integerValue] == 0)
                {
                    [fm removeItemAtPath:folder error:nil];
                    tmpURL = nil;
                    IMPORTDLog(@"unpack failed");
                }
            }

            if(tmpURL)
            {
                [self setExtractedFileURL:tmpURL];
                [self setArchiveFileIndex:i];
                [self setExploreArchives:NO];
            }
        }
    }
}

- (void)OE_performImportStepHash
{
    if([self md5Hash] || [self crcHash]) return;

    IMPORTDLog();
    NSURL         *url = [self extractedFileURL] ?: [self URL];
    NSString      *md5, *crc;
    NSError       *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if(![fileManager hashFileAtURL:url md5:&md5 crc32:&crc error:&error])
    {
        IMPORTDLog(@"unable to hash file, this is probably a fatal error");
        IMPORTDLog(@"%@", error);

        NSError *error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeNoHash userInfo:nil];
        [self exitWithStatus:OEImportExitErrorFatal error:error];
    }
    else
    {
        [self setMd5Hash:[md5 lowercaseString]];
        [self setCrcHash:[crc lowercaseString]];
    }

}

- (void)OE_performImportStepCheckHash
{
    IMPORTDLog();
    NSError  *error = nil;
    NSString *md5   = [self md5Hash];
    NSString *crc   = [self crcHash];
    NSManagedObjectContext *context = [[self importer] context];

    OEDBRom *rom = nil;

    if(rom == nil)
        rom = [OEDBRom romWithMD5HashString:md5 inContext:context error:&error];
    if(rom == nil)
        rom = [OEDBRom romWithCRC32HashString:crc inContext:context error:&error];

    if(rom != nil)
    {
        NSURL *romURL = [rom URL];
        [self setRom:rom];
        if(![romURL checkResourceIsReachableAndReturnError:&error])
        {
            IMPORTDLog(@"rom file not available");
            IMPORTDLog(@"%@", error);
            // TODO: depending on error finish here with 'already present' success
            // if the error says something like volume could not be found we might want to skip import because the file is probably on an external HD that is currently not connected
            // but if it just says the file was deleted we should replace the rom's url with the new one and continue importing
        }
        else
        {
            [self exitWithStatus:OEImportExitSuccess error:nil];
        }
    }
}

- (void)OE_performImportStepDetermineSystem
{
    IMPORTDLog(@"URL: %@", [self sourceURL]);
    if([self rom] != nil) return;

    NSError *error = nil;
    OEROMImporter *importer = [self importer];
    NSManagedObjectContext *context = [importer context];
    NSURL *url = [self extractedFileURL] ?: [self URL];

    // see if systemidentifiers are set already (meaning that user determined system)
    NSArray *validSystems = nil;
    if([self systemIdentifiers])
    {
        NSMutableArray *systems = [NSMutableArray arrayWithCapacity:[[self systemIdentifiers] count]];
        [[self systemIdentifiers] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            OEDBSystem *system = [OEDBSystem systemForPluginIdentifier:obj inContext:context];
            if(system != nil)
                [systems addObject:system];
        }];
        validSystems = systems;
    }
    else if([[NSUserDefaults standardUserDefaults] boolForKey:OEImportManualSystems])
    {
        validSystems = [OEDBSystem allSystemsInContext:context];
    }
    else
    {
        validSystems = [OEDBSystem systemsForFileWithURL:url inContext:context error:&error];
    }

    if(validSystems == nil || [validSystems count] == 0)
    {
        IMPORTDLog(@"Could not get valid systems");
        IMPORTDLog(@"%@", error);
        if([self extractedFileURL])
        {
            IMPORTDLog(@"Try again with zip itself");
            [self setExtractedFileURL:nil];
            [self OE_performImportStepDetermineSystem];
        }
        else
        {
            error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeNoSystem userInfo:nil];
            [self exitWithStatus:OEImportExitErrorFatal error:error];
        }
        return;
    }
    else if([validSystems count] == 1)
    {
        [self setSystemIdentifiers:@[[[validSystems lastObject] systemIdentifier]]];
    }
    else // Found multiple valid systems after checking extension and system specific canHandleFile:
    {
        NSMutableArray *systemIDs = [NSMutableArray arrayWithCapacity:[validSystems count]];
        [validSystems enumerateObjectsUsingBlock:^(OEDBSystem *system, NSUInteger idx, BOOL *stop){
            NSString *systemIdentifier = [system systemIdentifier];
            [systemIDs addObject:systemIdentifier];
        }];
        [self setSystemIdentifiers:systemIDs];

        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"Aaargh, too many systems. You need to choose one!" forKey:NSLocalizedDescriptionKey];
        error = [NSError errorWithDomain:OEImportErrorDomainResolvable code:OEImportErrorCodeMultipleSystems userInfo:userInfo];
        [self exitWithStatus:OEImportExitErrorResolvable error:error];
    }
}

- (void)OE_performImportStepCreateCoreDataObjects
{
    IMPORTDLog();

    NSManagedObjectContext *context = [[self importer] context];
    NSError *error = nil;
    OEDBRom *rom = [self rom];

    if(rom == nil)
    {
        rom = [OEDBRom createObjectInContext:context];
    }

    if(rom == nil)
    {
        NSError *error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeInvalidFile userInfo:nil];
        [self exitWithStatus:OEImportExitErrorFatal error:error];
        return;
    }

    NSString *md5 = [self md5Hash];
    NSString *crc = [self crcHash];

    [rom setURL:[self URL]];
    if([self fileName] != nil) [rom setFileName:[self fileName]];
    if(crc != nil) [rom setCrc32:[crc lowercaseString]];
    if(md5 != nil) [rom setMd5:[md5 lowercaseString]];

    // Check if system plugin for ROM implemented headerLookupForFile: and serialLookupForFile:
    NSAssert([[self systemIdentifiers] count] == 1, @"System should have been detected at an earlier import stage");
    NSString *systemIdentifier = [[self systemIdentifiers] lastObject];

    NSURL *lookupURL = [self extractedFileURL] ?: [rom URL];
    NSString *headerFound = [OEDBSystem headerForFileWithURL:lookupURL forSystem:systemIdentifier];
    NSString *serialFound = [OEDBSystem serialForFileWithURL:lookupURL forSystem:systemIdentifier];

    if(headerFound != nil)
    {
        [rom setHeader:headerFound];
    }

    if(serialFound != nil)
    {
        [rom setSerial:serialFound];
    }

    if([self archiveFileIndex] != NSNotFound)
        [rom setArchiveFileIndex:@([self archiveFileIndex])];

    OEDBGame *game = [rom game];
    if(game == nil)
    {
        NSString *systemIdentifier = [[self systemIdentifiers] lastObject];
        OEDBSystem *system = [OEDBSystem systemForPluginIdentifier:systemIdentifier inContext:context];
        if(system != nil)
        {
            NSURL *url = [self extractedFileURL] ?: [rom URL];
            NSString *gameTitleWithSuffix = [url lastPathComponent];
            NSString *gameTitleWithoutSuffix = [gameTitleWithSuffix stringByDeletingPathExtension];

            game = [OEDBGame createObjectInContext:context];
            [game setName:gameTitleWithoutSuffix];
            [game setSystem:system];
        }
        else
        {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"No system! Someone must have deleted or disabled it!" forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeNoSystem userInfo:userInfo];
            [self exitWithStatus:OEImportExitErrorFatal error:error];
            return;
        }
    }
    
    if(game != nil)
    {
        [rom setGame:game];

        if([[NSUserDefaults standardUserDefaults] boolForKey:OEAutomaticallyGetInfoKey])
        {
            [game setStatus:@(OEDBGameStatusProcessing)];
        }

        [self setRom:rom];

        [self exitWithStatus:OEImportExitSuccess error:nil];
    }
    else
    {
        [rom delete];
        [game delete];

        [self setRom:nil];
        NSError *error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeNoGame userInfo:nil];
        [self exitWithStatus:OEImportExitErrorFatal error:error];
    }
}
@end
