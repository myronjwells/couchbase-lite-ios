//
//  MessageEndpointTest.m
//  CouchbaseLite
//
//  Copyright (c) 2017 Couchbase, Inc All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "CBLTestCase.h"
#import <MultipeerConnectivity/MultipeerConnectivity.h>
#import "CBLMessageEndpointConnection.h"
#import "CBLMessage.h"
#import "CBLMessagingError.h"
#import "CBLMessageEndpoint.h"
#import "CBLMessageEndpointListener.h"

#ifndef COUCHBASE_ENTERPRISE
#error Couchbase Lite EE Only
#endif

typedef void (^OpenCompletion)(BOOL, CBLMessagingError * _Nullable);

@protocol MultipeerConnectionDelegate
- (void) connectionDidOpen: (id<CBLMessageEndpointConnection>)connection;
- (void) connectionDidClose: (id<CBLMessageEndpointConnection>)connection;
@end

@interface MultipeerConnection: NSObject <CBLMessageEndpointConnection>

@property (nonatomic, readonly) MCSession* session;
@property (nonatomic, readonly) MCPeerID* peerID;
@property (nonatomic, readonly, weak) id<MultipeerConnectionDelegate> delegate;
@property (nonatomic) OpenCompletion openCompletion;

- (instancetype) initWithSession: (MCSession*)session
                          peerID: (MCPeerID*)peerID
                        delegate: (id<MultipeerConnectionDelegate>)delegate
                      completion: (nullable OpenCompletion)openCompletion;

- (void) receiveData: (NSData*)data;

@end

@implementation MultipeerConnection {
    id<CBLReplicatorConnection> _replConnection;
}

@synthesize session=_session, peerID=_peerID, delegate=_delegate, openCompletion=_openCompletion;

- (instancetype) initWithSession: (MCSession*)session
                          peerID: (MCPeerID*)peerID
                        delegate: (id<MultipeerConnectionDelegate>)delegate
                      completion: (OpenCompletion)openCompletion
{
    self = [super init];
    if (self) {
        _session = session;
        _peerID = peerID;
        _delegate = delegate;
        _openCompletion = openCompletion;
    }
    return self;
}

- (void) receiveData: (NSData*)data {
    [_replConnection receive: [CBLMessage fromData: data]];
}

#pragma mark - CBLMessageEndpointConnection

- (void)open: (nonnull id<CBLReplicatorConnection>)connection
  completion:(nonnull void (^)(BOOL, CBLMessagingError * _Nullable))completion {
    _replConnection = connection;
    [_delegate connectionDidOpen: self];
    if (_openCompletion)
        _openCompletion(YES, nil);
    
    completion(YES, nil);
}

- (void)close: (nullable NSError*)error completion: (nonnull void (^)(void))completion {
    [_session disconnect];
    [_delegate connectionDidClose: self];
    completion();
}

- (void)send:(nonnull CBLMessage*)message
  completion:(nonnull void (^)(BOOL, CBLMessagingError * _Nullable))completion {
    NSError* error;
    BOOL success = [_session sendData: [message toData]
                              toPeers: @[_peerID]
                             withMode: MCSessionSendDataReliable
                                error: &error];
    NSLog(@"*** Sent %lu bytes to %@", (unsigned long)[message toData].length, _peerID.displayName);
    completion(success, error ? [[CBLMessagingError alloc] initWithError: error isRecoverable: NO] : nil);
}

@end

@interface MessageEndpointTest : CBLTestCase
<MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate,
MCSessionDelegate, CBLMessageEndpointDelegate, MultipeerConnectionDelegate>
@end

@implementation MessageEndpointTest {
    CBLDatabase* _otherDB;
    
    MCPeerID* _clientPeer;
    MCPeerID* _serverPeer;
    
    MCSession* _clientSession;
    MCSession* _serverSession;
    
    MCNearbyServiceBrowser* _browser;
    MCNearbyServiceAdvertiser* _advertiser;
    
    MultipeerConnection* _clientConnection;
    MultipeerConnection* _serverConnection;
    
    CBLReplicator* _replicator;
    CBLMessageEndpointListener* _listener;
    
    XCTestExpectation* _clientConnected;
    XCTestExpectation* _serverConnected;
}

// TODO: Remove https://issues.couchbase.com/browse/CBL-3206
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

- (void)setUp {
    [super setUp];
    
    NSError* error;
    _otherDB = [self openDBNamed: @"otherdb" error: &error];
    AssertNil(error);
    AssertNotNil(_otherDB);
}

- (void)tearDown {
    [_listener closeAll];
    
    // Note: as long as the reference is, config>collections are also not removed!
    _listener = nil;
    
    // Workaround to ensure that replicator's background cleaning task was done:
    // https://github.com/couchbase/couchbase-lite-core/issues/520
    [NSThread sleepForTimeInterval: 0.3];
    
    [_browser stopBrowsingForPeers];
    [_advertiser stopAdvertisingPeer];
    
    [_clientSession disconnect];
    [_serverSession disconnect];
    
    Assert([_otherDB close: nil]);
    _otherDB = nil;
    _replicator = nil;
    [super tearDown];
}

- (void) startDiscovery {
    // TODO: check whether this is a new issue introduced?
    // https://issues.couchbase.com/browse/CBL-3699
    _serverConnected = [self allowOverfillExpectationWithDescription: @"Server Connected"];
    _serverPeer = [[MCPeerID alloc] initWithDisplayName: @"server"];
    _serverSession = [[MCSession alloc] initWithPeer:_serverPeer
                                    securityIdentity: nil
                                encryptionPreference: MCEncryptionNone];
    _serverSession.delegate = self;
    
    _advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:_serverPeer
                                                    discoveryInfo: nil
                                                      serviceType: @"MyService"];
    _advertiser.delegate = self;
    [_advertiser startAdvertisingPeer];
    
    // TODO: check whether this is a new issue introduced?
    // https://issues.couchbase.com/browse/CBL-3699
    _clientConnected = [self allowOverfillExpectationWithDescription: @"Client Connected"];
    _clientPeer = [[MCPeerID alloc] initWithDisplayName: @"client"];
    _clientSession = [[MCSession alloc] initWithPeer: _clientPeer
                                    securityIdentity: nil
                                encryptionPreference: MCEncryptionNone];
    _clientSession.delegate = self;
    
    _browser = [[MCNearbyServiceBrowser alloc] initWithPeer: _clientPeer
                                                serviceType: @"MyService"];
    _browser.delegate = self;
    [_browser startBrowsingForPeers];
    
    // cool down period(disconnected to next connected state), is taking around 4-10secs
    [self waitForExpectations: @[_clientConnected, _serverConnected] timeout: 30.0];
}

- (void) run: (CBLReplicatorConfiguration*)config
   errorCode: (NSInteger)errorCode
 errorDomain: (NSString*)errorDomain
{
    [self run: config collection: nil errorCode: errorCode errorDomain: errorDomain];
}

- (void) run: (CBLReplicatorConfiguration*)config
  collection: (nullable NSArray*) cols
   errorCode: (NSInteger)errorCode
 errorDomain: (NSString*)errorDomain
{
    // Start discovery:
    [self startDiscovery];
    
    // Start listener:
    XCTestExpectation* x1 = [self expectationWithDescription: @"Listener Connecting"];
    XCTestExpectation* x2 = [self expectationWithDescription: @"Listener Stopped"];
    CBLMessageEndpointListenerConfiguration* listenerConfig = nil;
    
    if (cols) {
        listenerConfig = [[CBLMessageEndpointListenerConfiguration alloc] initWithCollections: cols
                                                                                 protocolType: kCBLProtocolTypeMessageStream];
    } else {
        listenerConfig = [[CBLMessageEndpointListenerConfiguration alloc] initWithDatabase: _otherDB
                                                                              protocolType: kCBLProtocolTypeMessageStream];
    }
    
    _listener = [[CBLMessageEndpointListener alloc] initWithConfig: listenerConfig];
    id token1 = [_listener addChangeListener: ^(CBLMessageEndpointListenerChange *change) {
        if (change.status.activity == kCBLReplicatorStopped)
            [x2 fulfill];
    }];
    [_listener accept: [[MultipeerConnection alloc] initWithSession: _serverSession
                                                             peerID: _clientPeer
                                                           delegate: self
                                                         completion: ^(BOOL s, CBLMessagingError * e) {
        [x1 fulfill];
    }]];
    [self waitForExpectations: @[x1] timeout: 10.0];
    
    // Start replicator:
    XCTestExpectation* x3 = [self expectationWithDescription: @"Replicator Stopped"];
    _replicator = [[CBLReplicator alloc] initWithConfig: config];
    __weak typeof(self) wSelf = self;
    id token2 = [_replicator addChangeListener: ^(CBLReplicatorChange* change) {
        typeof(self) strongSelf = wSelf;
        [strongSelf verifyChange: change errorCode: errorCode errorDomain:errorDomain];
        if (config.continuous && change.status.activity == kCBLReplicatorIdle
            && change.status.progress.completed == change.status.progress.total) {
            [strongSelf->_replicator stop];
        }
        if (change.status.activity == kCBLReplicatorStopped) {
            [x3 fulfill];
        }
    }];
    
    [_replicator start];
    
    [self waitForExpectations: @[x3] timeout: 10.0];
    [_replicator stop];
    [_replicator removeChangeListenerWithToken: token2];
    
    [_listener closeAll];
    [self waitForExpectations: @[x2] timeout: 10.0];
    [_listener removeChangeListenerWithToken: token1];
}

- (void) verifyChange: (CBLReplicatorChange*)change
            errorCode: (NSInteger)code
          errorDomain: (NSString*)domain
{
    CBLReplicatorStatus* s = change.status;
    static const char* const kActivityNames[5] = { "stopped", "offline", "connecting", "idle", "busy" };
    NSLog(@"---Status: %s (%llu / %llu), lastError = %@",
          kActivityNames[s.activity], s.progress.completed, s.progress.total,
          s.error.localizedDescription);
    
    if (s.activity == kCBLReplicatorStopped) {
        if (code != 0) {
            AssertEqual(s.error.code, code);
            if (domain)
                AssertEqualObjects(s.error.domain, domain);
        } else
            AssertNil(s.error);
    }
}

- (CBLReplicatorConfiguration*) configWithTarget: (id<CBLEndpoint>)target
                                            type: (CBLReplicatorType)type
                                      continuous: (BOOL)continuous
{
    CBLReplicatorConfiguration* c =
    [[CBLReplicatorConfiguration alloc] initWithDatabase: self.db
                                                  target: target];
    c.replicatorType = type;
    c.continuous = continuous;
    return c;
}

#pragma mark - MCNearbyServiceBrowserDelegate

- (void)browser:(nonnull MCNearbyServiceBrowser*)browser
      foundPeer:(nonnull MCPeerID*)peerID
withDiscoveryInfo: (nullable NSDictionary<NSString*,NSString*>*)info {
    [_browser invitePeer: peerID toSession: _clientSession withContext: nil timeout: 0.0];
}

- (void)browser:(nonnull MCNearbyServiceBrowser*)browser
       lostPeer:(nonnull MCPeerID*)peerID { }

- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error {
    NSLog(@"*** Multipeer browser ERROR: %@", error);
}

#pragma mark - MCNearbyServiceAdvertiserDelegate

- (void) advertiser: (nonnull MCNearbyServiceAdvertiser*)advertiser
didReceiveInvitationFromPeer: (nonnull MCPeerID*)peerID
        withContext: (nullable NSData*)context
  invitationHandler: (nonnull void (^)(BOOL, MCSession* _Nullable))invitationHandler {
    invitationHandler(YES, _serverSession);
}

- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error {
    NSLog(@"*** Multipeer advertiser ERROR: %@", error);
}

#pragma mark - MCSessionDelegate

- (void) session: (nonnull MCSession*)session
            peer: (nonnull MCPeerID*)peerID
  didChangeState: (MCSessionState)state {
    if (state == MCSessionStateConnecting) {
        NSLog(@"*** Connecting : %@", peerID.displayName);
    } else if (state == MCSessionStateConnected) {
        NSLog(@"*** Connected : %@", peerID.displayName);
        if (session == _serverSession)
            [_serverConnected fulfill];
        else
            [_clientConnected fulfill];
    } else if (state == MCSessionStateNotConnected) {
        NSLog(@"*** Not Connected : %@", peerID.displayName);
    }
}

- (void) session:(nonnull MCSession*)session
  didReceiveData: (nonnull NSData*)data
        fromPeer: (nonnull MCPeerID*)peerID {
    NSLog(@"*** Received %lu bytes from %@", (unsigned long)data.length, peerID.displayName);
    if (session == _serverSession)
        [_serverConnection receiveData: data];
    else
        [_clientConnection receiveData: data];
}

- (void) session: (nonnull MCSession*)session
didFinishReceivingResourceWithName: (nonnull NSString*)resourceName
        fromPeer: (nonnull MCPeerID*)peerID
           atURL: (nullable NSURL*)localURL
       withError: (nullable NSError*)error { /* Not supported */ }

- (void) session: (nonnull MCSession*)session
didReceiveStream: (nonnull NSInputStream*)stream
        withName: (nonnull NSString*)streamName
        fromPeer: (nonnull MCPeerID*)peerID { /* Not supported */ }

- (void) session: (nonnull MCSession*)session
didStartReceivingResourceWithName: (nonnull NSString*)resourceName
        fromPeer: (nonnull MCPeerID*)peerID
    withProgress: (nonnull NSProgress*)progress { /* Not supported */ }

#pragma mark - MultipeerConnectionDelegate

- (void) connectionDidOpen: (id<CBLMessageEndpointConnection>)connection {
    MultipeerConnection* conn = (MultipeerConnection*)connection;
    if (conn.session == _serverSession)
        _serverConnection = connection;
    else
        _clientConnection = connection;
}

- (void) connectionDidClose: (id<CBLMessageEndpointConnection>)connection {
    MultipeerConnection* conn = (MultipeerConnection*)connection;
    if (conn.session == _serverSession)
        _serverConnection = nil;
    else
        _clientConnection = nil;
}

#pragma mark - CBLMessageEndpointDelegate

- (nonnull id<CBLMessageEndpointConnection>)createConnectionForEndpoint: (CBLMessageEndpoint*)endpoint {
    return [[MultipeerConnection alloc] initWithSession: _clientSession
                                                 peerID: _serverPeer
                                               delegate: self
                                             completion: nil];
}

#pragma mark - Tests

- (void) testPushDoc {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePush continuous: NO];
    [self run: config errorCode: 0 errorDomain: nil];
    
    AssertEqual(_otherDB.count, 2u);
    CBLDocument* savedDoc = [_otherDB documentWithID: @"doc1"];
    AssertEqualObjects([savedDoc stringForKey:@"name"], @"Tiger");
}

- (void) testPullDoc {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePull continuous: NO];
    // Ignore internal exception thrown inside Apple MultipeerConnection Framework
    // for unknown reason:
    [self ignoreException: ^{
        [self run: config errorCode: 0 errorDomain: nil];
    }];
    
    AssertEqual(_db.count, 2u);
    CBLDocument* savedDoc = [_db documentWithID: @"doc2"];
    AssertEqualObjects([savedDoc stringForKey:@"name"], @"Cat");
}

- (void) testPushPullDoc {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePushAndPull continuous: NO];
    [self run: config errorCode: 0 errorDomain: nil];
    
    AssertEqual(_otherDB.count, 2u);
    CBLDocument* savedDoc1 = [_db documentWithID: @"doc1"];
    AssertEqualObjects([savedDoc1 stringForKey:@"name"], @"Tiger");
    
    AssertEqual(_db.count, 2u);
    CBLDocument* savedDoc2 = [_db documentWithID: @"doc2"];
    AssertEqualObjects([savedDoc2 stringForKey:@"name"], @"Cat");
}

- (void) testPushDocContinuous {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePush continuous: YES];
    [self run: config errorCode: 0 errorDomain: nil];
    
    AssertEqual(_otherDB.count, 2u);
    CBLDocument* savedDoc = [_otherDB documentWithID: @"doc1"];
    AssertEqualObjects([savedDoc stringForKey:@"name"], @"Tiger");
}

- (void) testPullDocContinuous {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePull continuous: NO];
    [self run: config errorCode: 0 errorDomain: nil];
    
    AssertEqual(_db.count, 2u);
    CBLDocument* savedDoc = [_db documentWithID: @"doc2"];
    AssertEqualObjects([savedDoc stringForKey:@"name"], @"Cat");
}

- (void) testPushPullDocContinuous {
    NSError* error;
    CBLMutableDocument* doc1 = [[CBLMutableDocument alloc] initWithID: @"doc1"];
    [doc1 setValue: @"Tiger" forKey: @"name"];
    Assert([self.db saveDocument: doc1 error: &error]);
    
    CBLMutableDocument* doc2 = [[CBLMutableDocument alloc] initWithID: @"doc2"];
    [doc2 setValue: @"Cat" forKey: @"name"];
    Assert([_otherDB saveDocument: doc2 error: &error]);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    id config = [self configWithTarget: target type: kCBLReplicatorTypePushAndPull continuous: YES];
    [self run: config errorCode: 0 errorDomain: nil];
    
    AssertEqual(_otherDB.count, 2u);
    CBLDocument* savedDoc1 = [_db documentWithID: @"doc1"];
    AssertEqualObjects([savedDoc1 stringForKey:@"name"], @"Tiger");
    
    AssertEqual(_db.count, 2u);
    CBLDocument* savedDoc2 = [_db documentWithID: @"doc2"];
    AssertEqualObjects([savedDoc2 stringForKey:@"name"], @"Cat");
}

#pragma mark - 8.16 MessageEndpointListener tests

- (void) testCollectionsSingleShotPushPullReplication {
    [self testCollectionsPushPullReplication: NO];
}

- (void) testCollectionsContinuousPushPullReplication {
    [self testCollectionsPushPullReplication: YES];
}

- (void) testCollectionsPushPullReplication: (BOOL)isContinous {
    NSError* error = nil;
    CBLCollection* col1a = [self.db createCollectionWithName: @"colA"
                                                       scope: @"scopeA" error: &error];
    AssertNotNil(col1a);
    AssertNil(error);
    
    CBLCollection* col1b = [self.db createCollectionWithName: @"colB"
                                                       scope: @"scopeA" error: &error];
    AssertNotNil(col1b);
    AssertNil(error);
    
    CBLCollection* col2a = [_otherDB createCollectionWithName: @"colA"
                                                        scope: @"scopeA" error: &error];
    AssertNotNil(col2a);
    AssertNil(error);
    
    CBLCollection* col2b = [_otherDB createCollectionWithName: @"colB"
                                                        scope: @"scopeA" error: &error];
    AssertNotNil(col2b);
    AssertNil(error);
    
    [self createDocNumbered: col1a start: 0 num: 1];
    [self createDocNumbered: col1b start: 5 num: 2];
    [self createDocNumbered: col2a start: 10 num: 3];
    [self createDocNumbered: col2b start: 15 num: 5];
    AssertEqual(col1a.count, 1);
    AssertEqual(col1b.count, 2);
    AssertEqual(col2a.count, 3);
    AssertEqual(col2b.count, 5);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    CBLReplicatorConfiguration* config = [[CBLReplicatorConfiguration alloc] initWithTarget: target];
    config.continuous = isContinous;
    [config addCollections: @[col1a, col1b] config: nil];
    
    [self run: config collection: @[col2a, col2b] errorCode: 0 errorDomain: nil];
    AssertEqual(col1a.count, 4);
    AssertEqual(col1b.count, 7);
    AssertEqual(col2a.count, 4);
    AssertEqual(col2b.count, 7);
}

- (void) testMismatchedCollectionReplication {
    NSError* error = nil;
    CBLCollection* col1a = [self.db createCollectionWithName: @"colA"
                                                       scope: @"scopeA" error: &error];
    AssertNotNil(col1a);
    AssertNil(error);
    
    CBLCollection* col2a = [_otherDB createCollectionWithName: @"colB"
                                                        scope: @"scopeA" error: &error];
    AssertNotNil(col2a);
    AssertNil(error);
    
    CBLCollection* defaultCollection = [_otherDB defaultCollection: &error];
    AssertNotNil(defaultCollection);
    AssertNil(error);
    
    id target = [[CBLMessageEndpoint alloc] initWithUID: @"UID:123"
                                                 target: nil
                                           protocolType: kCBLProtocolTypeMessageStream
                                               delegate: self];
    
    CBLReplicatorConfiguration* config = [[CBLReplicatorConfiguration alloc] initWithTarget: target];
    [config addCollections: @[col1a] config: nil];
    
    [self run: config collection: @[col2a] errorCode: CBLErrorHTTPNotFound errorDomain: CBLErrorDomain];
}

- (void) testCreateListenerConfigWithEmptyCollection {
    [self expectException: NSInvalidArgumentException in:^{
        id config = [[CBLMessageEndpointListenerConfiguration alloc] initWithCollections: @[]
                                                                            protocolType: kCBLProtocolTypeMessageStream];
        NSLog(@"%@", config);
    }];
}

#pragma clang diagnostic pop

- (void) testCollection {
    NSError* error = nil;
    CBLCollection* collection = [self.db createCollectionWithName: @"collection1"
                                                            scope: @"scope1"
                                                            error: &error];
    CBLMessageEndpointListenerConfiguration* config;
    config = [[CBLMessageEndpointListenerConfiguration alloc] initWithCollections: @[collection]
                                                                     protocolType: kCBLProtocolTypeByteStream];
    
    AssertEqual(config.collections.count, 1);
    CBLCollection* c = (CBLCollection*)config.collections.firstObject;
    AssertEqualObjects(c.name, @"collection1");
}

@end
