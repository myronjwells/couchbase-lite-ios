//
//  CBLQueryOrderBy.h
//  CouchbaseLite
//
//  Created by Pasin Suriyentrakorn on 3/8/17.
//  Copyright © 2017 Couchbase. All rights reserved.
//

#import <Foundation/Foundation.h>
@class CBLQuerySortOrder, CBLQueryExpression;

NS_ASSUME_NONNULL_BEGIN

/** An CBLQueryOrderBy represents a query ORDER BY clause of a SQL or N1QL query by sepecifying
 properties or expressions that the result rows should be sorted by. 
 A CBLQueryOrderBy can be construct as a single CBLQuerySortOrder instance with a propery name 
 or an expression instance or as a chain of multiple CBLQueryOrderBy instances. */
@interface CBLQueryOrderBy : NSObject

/** Construct a chain of multiple CBLQueryOrderBy instances. */
+ (CBLQueryOrderBy*) orderBy: (CBLQueryOrderBy *)orderBy, ...;

/** Construct a CBLQuerySortOrder instance with a given property name. */
+ (CBLQuerySortOrder*) property: (NSString*)name;

/** Construct a CBLQuerySortOrder instance with a given expression. */
+ (CBLQuerySortOrder*) expression: (CBLQueryExpression*)expression;

- (instancetype) init NS_UNAVAILABLE;

@end

/** CBLQuerySortOrder is a subclass of the CBLQueryOrderBy that allows to create an 
 ascending or a descending CBLQueryOrderBy object. */
@interface CBLQuerySortOrder : CBLQueryOrderBy

/** Create an ascending CBLQueryOrderBy object. */
- (CBLQueryOrderBy*) ascending;

/** Create a descending CBLQueryOrderBy object. */
- (CBLQueryOrderBy*) descending;

- (instancetype) init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
