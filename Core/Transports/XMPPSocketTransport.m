//
//  XMPPSocketTransport.m
//  iPhoneXMPP
//
//  Created by Chaitanya Gupta on 16/03/11.
//  Copyright 2011 Directi. All rights reserved.
//

#import "XMPPSocketTransport.h"
#import "MulticastDelegate.h"
#import "AsyncSocket.h"
#import "XMPPParser.h"
#import "NSXMLElementAdditions.h"
#import "XMPPJID.h"

@interface XMPPSocketTransport ()
- (void)sendOpeningNegotiation;
@end

@implementation XMPPSocketTransport

@synthesize host;
@synthesize myJID;
@synthesize remoteJID;
@synthesize isP2PRecipient;

- (id)init
{
    self = [super init];
    if (self)
    {
        multicastDelegate = [[MulticastDelegate alloc] init];
        parser = [[XMPPParser alloc] initWithDelegate:self];
        isSecure = NO;
        numberOfBytesSent = 0;
        numberOfBytesReceived = 0;
    }
    return self;
}

- (id)initWithHost:(NSString *)givenHost port:(UInt16)givenPort
{
    self = [self init];
    if (self)
    {
        asyncSocket = [[AsyncSocket alloc] initWithDelegate:self];
        host = givenHost;
        port = givenPort;
        state = XMPP_SOCKET_DISCONNECTED;
    }
    return self;
}

- (id)initP2PWithHost:(NSString *)givenHost port:(UInt16)givenPort
{
    self = [self initWithHost:givenHost port:givenPort];
    if (self)
    {
        isP2P = YES;
    }
    return self;
}

- (id)initP2PWithSocket:(AsyncSocket *)socket
{
    self = [self init];
    if (self)
    {
        asyncSocket = [socket retain];
        [asyncSocket setDelegate:self];
        state = XMPP_SOCKET_OPENING;
        isP2P = YES;
        isP2PRecipient = YES;
    }
    return self;
}

- (void)addDelegate:(id)delegate
{
    [multicastDelegate addDelegate:delegate];
}

- (void)removeDelegate:(id)delegate
{
    [multicastDelegate removeDelegate:delegate];
}

- (BOOL)connect:(NSError **)errPtr
{
    if (isP2P && isP2PRecipient)
    {
        // Start reading in the peer's XML stream
        [asyncSocket readDataWithTimeout:TIMEOUT_READ_START tag:TAG_READ_START];
        return YES;
    } 
    else 
    {
        state = XMPP_SOCKET_OPENING;
        return [asyncSocket connectToHost:host onPort:port error:errPtr];
    }
}

- (void)disconnect
{
    [self sendStanzaWithString:@"</stream:stream>"];
    [multicastDelegate transportWillDisconnect:self];
    [asyncSocket disconnect];
}

/**
 * Returns the version attribute from the servers's <stream:stream/> element.
 * This should be at least 1.0 to be RFC 3920 compliant.
 * If no version number was set, the server is not RFC compliant, and 0 is returned.
 **/
- (float)serverXmppStreamVersionNumber
{
	return [rootElement attributeFloatValueForName:@"version" withDefaultValue:0.0F];
}

- (BOOL)sendStanza:(NSXMLElement *)stanza
{
    return [self sendStanzaWithString:[stanza compactXMLString]];
}

- (BOOL)sendStanzaWithString:(NSString *)string
{
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	DDLogSend(@"SEND: %@", string);
	numberOfBytesSent += [data length];
	[asyncSocket writeData:data
	           withTimeout:TIMEOUT_WRITE
	                   tag:TAG_WRITE_STREAM];
    return YES; // FIXME: does this need to be a BOOL?
}

/**
 * This method handles starting TLS negotiation on the socket, using the proper settings.
 **/
- (void)secure
{
	// Create a mutable dictionary for security settings
	NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:5];
	
	// Prompt the delegate(s) to populate the security settings
	[multicastDelegate transport:self willSecureWithSettings:settings];

	// If the delegates didn't respond
	if ([settings count] == 0)
	{
		// Use the default settings, and set the peer name
		if (host)
		{
			[settings setObject:host forKey:(NSString *)kCFStreamSSLPeerName];
		}
	}
	[asyncSocket startTLS:settings];
}

- (BOOL)isSecure
{
    return isSecure;
}

/**
 * This method handles sending the opening <stream:stream ...> element which is needed in several situations.
 **/
- (void)sendOpeningNegotiation
{
	BOOL isRenegotiation = NO;
	
	if ((state == XMPP_SOCKET_OPENING) || (state == XMPP_SOCKET_RESTARTING))
	{
		// TCP connection was just opened - We need to include the opening XML stanza
		NSString *s1 = @"<?xml version='1.0'?>";
		
        [self sendStanzaWithString:s1];
	}

	if (state != XMPP_SOCKET_OPENING)
	{
		// We're restarting our negotiation.
		// This happens, for example, after securing the connection with SSL/TLS.
		isRenegotiation = YES;
		
		// Since we're restarting the XML stream, we need to reset the parser.
		[parser stop];
		[parser release];
		
		parser = [(XMPPParser *)[XMPPParser alloc] initWithDelegate:self];
	}
	else if (parser == nil)
	{
		// Need to create parser (it was destroyed when the socket was last disconnected)
		parser = [(XMPPParser *)[XMPPParser alloc] initWithDelegate:self];
	}
	
	NSString *xmlns = @"jabber:client";
	NSString *xmlns_stream = @"http://etherx.jabber.org/streams";
	
	NSString *temp, *s2;

    if (isP2P)
    {
        if (myJID && remoteJID)
		{
			temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' from='%@' to='%@'>";
			s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, [myJID bare], [remoteJID bare]];
		}
		else if (myJID)
		{
			temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' from='%@'>";
			s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, [myJID bare]];
		}
		else if (remoteJID)
		{
			temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' to='%@'>";
			s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, [remoteJID bare]];
		}
		else
		{
			temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0'>";
			s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream];
		}
    }
    else
    {
        if (myJID)
        {
            temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' to='%@'>";
            s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, [myJID domain]];
        }
        else if ([host length] > 0)
        {
            temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0' to='%@'>";
            s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream, host];
        }
        else
        {
            temp = @"<stream:stream xmlns='%@' xmlns:stream='%@' version='1.0'>";
            s2 = [NSString stringWithFormat:temp, xmlns, xmlns_stream];
        }
    }
    
    [self sendStanzaWithString:s2];

	// Update status
	state = XMPP_SOCKET_NEGOTIATING;
	
	// For a reneogitation, we need to manually read from the socket.
	// This is because we had to reset our parser, which is usually used to continue the reading process.
	if (isRenegotiation)
	{
		[asyncSocket readDataWithTimeout:TIMEOUT_READ_START tag:TAG_READ_START];
	}
}

- (void)restartStream
{
    state = XMPP_SOCKET_RESTARTING;
    [self sendOpeningNegotiation];
}

//////////////////////////////////
#pragma mark AsyncSocket Delegate
//////////////////////////////////
- (BOOL)onSocketWillConnect:(AsyncSocket *)socket
{
    [multicastDelegate transportWillConnect:self];
    return YES;
}

- (void)onSocket:(AsyncSocket *)socket didConnectToHost:(NSString *)givenHost port:(UInt16)givenPort
{
    [self sendOpeningNegotiation];
    [multicastDelegate transportDidStartNegotiation:self];
    // And start reading in the server's XML stream
	[asyncSocket readDataWithTimeout:TIMEOUT_READ_START tag:TAG_READ_START];
}

/**
 * Called when a socket has completed reading the requested data. Not called if there is an error.
 **/
- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
	if (DEBUG_RECV_PRE)
	{
		NSString *dataAsStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		DDLogRecvPre(@"RECV RAW: %@", dataAsStr);
		[dataAsStr release];
	}

	numberOfBytesReceived += [data length];
	[parser parseData:data];
}

- (void)onSocketDidSecure:(AsyncSocket *)sock
{
    isSecure = YES;
    [multicastDelegate transportDidSecure:self];
}

- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err
{
    [multicastDelegate transportWillDisconnect:self withError:err];
}

- (void)onSocketDidDisconnect:(AsyncSocket *)sock
{
    [multicastDelegate transportDidDisconnect:self];
}

//////////////////////////////////////
#pragma mark XMPPParser Delegate
//////////////////////////////////////

- (void)xmppParser:(XMPPParser *)sender didParseDataOfLength:(NSUInteger)length
{
	// The chunk we read has now been fully parsed.
	// Continue reading for XML elements.
	if(state == XMPP_SOCKET_OPENING)
	{
		[asyncSocket readDataWithTimeout:TIMEOUT_READ_START tag:TAG_READ_START];
	}
	else
	{
		[asyncSocket readDataWithTimeout:TIMEOUT_READ_STREAM tag:TAG_READ_STREAM];
	}
}

/**
 * Called when the xmpp parser has read in the entire root element.
 **/
- (void)xmppParser:(XMPPParser *)sender didReadRoot:(NSXMLElement *)root
{
	DDLogRecvPost(@"RECV: %@", [root compactXMLString]);
    
    if (isP2PRecipient)
    {
        NSLog(@"didReadRoot");
        self.remoteJID = [XMPPJID jidWithString:[root attributeStringValueForName:@"from"]];
        [self sendOpeningNegotiation];
        [multicastDelegate transportDidStartNegotiation:self];
    }

	// At this point we've sent our XML stream header, and we've received the response XML stream header.
	// We save the root element of our stream for future reference.
	// Digest Access authentication requires us to know the ID attribute from the <stream:stream/> element.

    [rootElement release];
    rootElement = [root retain];
    state = XMPP_SOCKET_CONNECTED;
    [multicastDelegate transportDidConnect:self];
}

- (void)xmppParser:(XMPPParser *)sender didReadElement:(NSXMLElement *)element
{
    DDLogRecvPost(@"RECV: %@", [element compactXMLString]);
    [multicastDelegate transport:self didReceiveStanza:element];
}

@end