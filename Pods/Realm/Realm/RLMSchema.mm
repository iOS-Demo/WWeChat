////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSchema_Private.h"

#import "RLMAccessor.h"
#import "RLMObject_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

#import "object_store.hpp"
#import "schema.hpp"

#import <realm/group.hpp>

#import <objc/runtime.h>
#include <mutex>

using namespace realm;

const uint64_t RLMNotVersioned = realm::ObjectStore::NotVersioned;

// RLMSchema private properties
@interface RLMSchema ()
@property (nonatomic, readwrite) NSMutableDictionary *objectSchemaByName;
@end

static RLMSchema *s_sharedSchema = [[RLMSchema alloc] init];
static NSMutableDictionary *s_localNameToClass = [[NSMutableDictionary alloc] init];
static NSMutableDictionary *s_privateObjectSubclasses = [[NSMutableDictionary alloc] init];

static enum class SharedSchemaState {
    Uninitialized,
    Initializing,
    Initialized
} s_sharedSchemaState = SharedSchemaState::Uninitialized;

// Caller must @synchronize on s_localNameToClass
static RLMObjectSchema *RLMRegisterClass(Class cls) {
    if (RLMObjectSchema *schema = s_privateObjectSubclasses[[cls className]]) {
        return schema;
    }

    auto prevState = s_sharedSchemaState;
    s_sharedSchemaState = SharedSchemaState::Initializing;
    RLMObjectSchema *schema = [RLMObjectSchema schemaForObjectClass:cls];
    s_sharedSchemaState = prevState;

    // set unmanaged class on shared shema for unmanaged object creation
    schema.standaloneClass = RLMStandaloneAccessorClassForObjectClass(schema.objectClass, schema);

    // override sharedSchema class methods for performance
    RLMReplaceSharedSchemaMethod(cls, schema);

    s_privateObjectSubclasses[schema.className] = schema;
    if ([cls shouldIncludeInDefaultSchema]) {
        s_sharedSchema.objectSchemaByName[schema.className] = schema;
    }

    return schema;
}

// Caller must @synchronize on s_localNameToClass
static void RLMRegisterClassLocalNames(Class *classes, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        Class cls = classes[i];

        if (!RLMIsObjectSubclass(cls) || RLMIsGeneratedClass(cls)) {
            continue;
        }

        NSString *className = NSStringFromClass(cls);
        if ([RLMSwiftSupport isSwiftClassName:className]) {
            className = [RLMSwiftSupport demangleClassName:className];
        }
        // NSStringFromClass demangles the names for top-level Swift classes
        // but not for nested classes. _T indicates it's a Swift symbol, t
        // indicates it's a type, and C indicates it's a class.
        else if ([className hasPrefix:@"_TtC"]) {
            @throw RLMException(@"RLMObject subclasses cannot be nested within other declarations. Please move %@ to global scope.", className);
        }

        if (Class existingClass = s_localNameToClass[className]) {
            if (existingClass != cls) {
                @throw RLMException(@"RLMObject subclasses with the same name cannot be included twice in the same target. "
                                    @"Please make sure '%@' is only linked once to your current target.", className);
            }
            continue;
        }

        s_localNameToClass[className] = cls;
        RLMReplaceClassNameMethod(cls, className);
    }
}

@implementation RLMSchema {
    NSArray *_objectSchema;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _objectSchemaByName = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (NSArray *)objectSchema {
    if (!_objectSchema) {
        _objectSchema = [_objectSchemaByName allValues];
    }
    return _objectSchema;
}

- (void)setObjectSchema:(NSArray *)objectSchema {
    _objectSchema = objectSchema;
    _objectSchemaByName = [NSMutableDictionary dictionaryWithCapacity:objectSchema.count];
    for (RLMObjectSchema *object in objectSchema) {
        [_objectSchemaByName setObject:object forKey:object.className];
    }
}

- (RLMObjectSchema *)schemaForClassName:(NSString *)className {
    return _objectSchemaByName[className];
}

- (RLMObjectSchema *)objectForKeyedSubscript:(__unsafe_unretained id<NSCopying> const)className {
    RLMObjectSchema *schema = _objectSchemaByName[className];
    if (!schema) {
        @throw RLMException(@"Object type '%@' not persisted in Realm", className);
    }
    return schema;
}

+ (instancetype)schemaWithObjectClasses:(NSArray *)classes {
    NSUInteger count = classes.count;
    auto classArray = std::make_unique<__unsafe_unretained Class[]>(count);
    [classes getObjects:classArray.get() range:NSMakeRange(0, count)];

    RLMSchema *schema = [[self alloc] init];
    @synchronized(s_localNameToClass) {
        RLMRegisterClassLocalNames(classArray.get(), count);

        schema->_objectSchemaByName = [NSMutableDictionary dictionaryWithCapacity:count];
        for (Class cls in classes) {
            if (!RLMIsObjectSubclass(cls)) {
                @throw RLMException(@"Can't add non-Object type '%@' to a schema.", cls);
            }
            schema->_objectSchemaByName[[cls className]] = RLMRegisterClass(cls);
        }
    }

    NSMutableArray *errors = [NSMutableArray new];
    // Verify that all of the targets of links are included in the class list
    [schema->_objectSchemaByName enumerateKeysAndObjectsUsingBlock:^(id, RLMObjectSchema *objectSchema, BOOL *) {
        for (RLMProperty *prop in objectSchema.properties) {
            if (prop.type != RLMPropertyTypeObject && prop.type != RLMPropertyTypeArray) {
                continue;
            }
            if (!schema->_objectSchemaByName[prop.objectClassName]) {
                [errors addObject:[NSString stringWithFormat:@"- '%@.%@' links to class '%@', which is missing from the list of classes to persist", objectSchema.className, prop.name, prop.objectClassName]];
            }
        }
    }];
    if (errors.count) {
        @throw RLMException(@"Invalid class subset list:\n%@", [errors componentsJoinedByString:@"\n"]);
    }

    return schema;
}

+ (RLMObjectSchema *)sharedSchemaForClass:(Class)cls {
    @synchronized(s_localNameToClass) {
        // We create instances of Swift objects during schema init, and they
        // obviously need to not also try to initialize the schema
        if (s_sharedSchemaState == SharedSchemaState::Initializing) {
            return nil;
        }

        RLMRegisterClassLocalNames(&cls, 1);
        return RLMRegisterClass(cls);
    }
}

+ (instancetype)partialSharedSchema {
    return s_sharedSchema;
}

// schema based on runtime objects
+ (instancetype)sharedSchema {
    @synchronized(s_localNameToClass) {
        // We replace this method with one which just returns s_sharedSchema
        // once initialization is complete, but we still need to check if it's
        // already complete because it may have been done by another thread
        // while we were waiting for the lock
        if (s_sharedSchemaState == SharedSchemaState::Initialized) {
            return s_sharedSchema;
        }

        if (s_sharedSchemaState == SharedSchemaState::Initializing) {
            @throw RLMException(@"Illegal recursive call of +[%@ %@]. Note: Properties of Swift `Object` classes must not be prepopulated with queried results from a Realm.", self, NSStringFromSelector(_cmd));
        }

        s_sharedSchemaState = SharedSchemaState::Initializing;
        try {
            // Make sure we've discovered all classes
            {
                unsigned int numClasses;
                using malloc_ptr = std::unique_ptr<__unsafe_unretained Class[], decltype(&free)>;
                malloc_ptr classes(objc_copyClassList(&numClasses), &free);
                RLMRegisterClassLocalNames(classes.get(), numClasses);
            }

            [s_localNameToClass enumerateKeysAndObjectsUsingBlock:^(NSString *, Class cls, BOOL *) {
                RLMRegisterClass(cls);
            }];
        }
        catch (...) {
            s_sharedSchemaState = SharedSchemaState::Uninitialized;
            throw;
        }

        // Replace this method with one that doesn't need to acquire a lock
        Class metaClass = objc_getMetaClass(class_getName(self));
        IMP imp = imp_implementationWithBlock(^{ return s_sharedSchema; });
        class_replaceMethod(metaClass, @selector(sharedSchema), imp, "@@:");

        s_sharedSchemaState = SharedSchemaState::Initialized;
    }

    return s_sharedSchema;
}

// schema based on tables in a realm
+ (instancetype)dynamicSchemaFromObjectStoreSchema:(Schema &)objectStoreSchema {
    // cache descriptors for all subclasses of RLMObject
    NSMutableArray *schemaArray = [NSMutableArray arrayWithCapacity:objectStoreSchema.size()];
    for (auto &objectSchema : objectStoreSchema) {
        RLMObjectSchema *schema = [RLMObjectSchema objectSchemaForObjectStoreSchema:objectSchema];
        [schemaArray addObject:schema];
    }

    // set class array and mapping
    RLMSchema *schema = [RLMSchema new];
    schema.objectSchema = schemaArray;
    return schema;
}

+ (Class)classForString:(NSString *)className {
    if (Class cls = s_localNameToClass[className]) {
        return cls;
    }

    if (Class cls = NSClassFromString(className)) {
        return RLMIsObjectSubclass(cls) ? cls : nil;
    }

    // className might be the local name of a Swift class we haven't registered
    // yet, so scan them all then recheck
    {
        unsigned int numClasses;
        std::unique_ptr<__unsafe_unretained Class[], decltype(&free)> classes(objc_copyClassList(&numClasses), &free);
        RLMRegisterClassLocalNames(classes.get(), numClasses);
    }

    return s_localNameToClass[className];
}

- (id)copyWithZone:(NSZone *)zone {
    RLMSchema *schema = [[RLMSchema allocWithZone:zone] init];
    schema->_objectSchemaByName = [[NSMutableDictionary allocWithZone:zone]
                                   initWithDictionary:_objectSchemaByName copyItems:YES];
    return schema;
}

- (instancetype)shallowCopy {
    RLMSchema *schema = [[RLMSchema alloc] init];
    schema->_objectSchemaByName = [[NSMutableDictionary alloc] initWithCapacity:_objectSchemaByName.count];
    [_objectSchemaByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, RLMObjectSchema *objectSchema, BOOL *) {
        schema->_objectSchemaByName[name] = [objectSchema shallowCopy];
    }];
    return schema;
}

- (BOOL)isEqualToSchema:(RLMSchema *)schema {
    if (_objectSchemaByName.count != schema->_objectSchemaByName.count) {
        return NO;
    }
    __block BOOL matches = YES;
    [_objectSchemaByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, RLMObjectSchema *objectSchema, BOOL *stop) {
        if (![schema->_objectSchemaByName[name] isEqualToObjectSchema:objectSchema]) {
            *stop = YES;
            matches = NO;
        }
    }];
    return matches;
}

- (NSString *)description {
    NSMutableString *objectSchemaString = [NSMutableString string];
    NSArray *sort = @[[NSSortDescriptor sortDescriptorWithKey:@"className" ascending:YES]];
    for (RLMObjectSchema *objectSchema in [self.objectSchema sortedArrayUsingDescriptors:sort]) {
        [objectSchemaString appendFormat:@"\t%@\n",
         [objectSchema.description stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    return [NSString stringWithFormat:@"Schema {\n%@}", objectSchemaString];
}

- (std::unique_ptr<Schema>)objectStoreCopy {
    std::vector<realm::ObjectSchema> schema;
    schema.reserve(_objectSchemaByName.count);
    [_objectSchemaByName enumerateKeysAndObjectsUsingBlock:[&](NSString *, RLMObjectSchema *objectSchema, BOOL *) {
        schema.push_back(objectSchema.objectStoreCopy);
    }];
    return std::make_unique<realm::Schema>(std::move(schema));
}

@end
