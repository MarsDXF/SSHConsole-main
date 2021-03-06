//
//  SSHConsole.swift
//
//  Created by Jim Studt on 11/20/20.
//
//  SPDX-License-Identifier: MIT
//

import Foundation

import Crypto
import NIO
import NIOSSH

/// Implement a security policy for password authentication
public protocol SSHPasswordDelegate {
    
    /// Decide if a username/password pair is valid for authentication.
    ///
    /// You should get off into a DispatchQueue or EventLoop if you need to do any IO to answer
    /// this question. Don't hang this thread.
    ///
    /// - Important: The `completion` parameter *must* be called exactly once.
    ///
    /// - Parameters:
    ///   - username: The username
    ///   - password: The password
    ///   - completion: A completion routine to report the validity. Must be called exactly once.
    ///
    func authenticate( username:String, password:String, completion: @escaping ((Bool)->Void) )
}

/// Implement a security policy for public key authentication
public protocol SSHPublicKeyDelegate {
    /// Decide if a public key is acceptable for authentication.
    ///
    /// This doesn't *do* anything about the key checking, that happens later without your
    /// help. This just says "Would I accept the owner of this key as authenticated?"
    ///
    /// You should get off into a DispatchQueue or EventLoop if you need to do any IO to answer
    /// this question. Don't hang this thread.
    ///
    /// You will find methods on the publicKey to check against OpenSSH formatted textual keys.
    ///
    /// - Parameters:
    ///   - username: The username
    ///   - publicKey: The binary public key, see methods for accessing.
    ///   - completion: A completion routine to report the validity. Must be called exactly once.
    ///
    func authenticate( username:String, publicKey:SSHConsole.PublicKey, completion: @escaping ((Bool)->Void) )
}

/// SSHConsole provides a listener on a host's port for the SSH protocol and dispatches
/// received commands to a specified handler.
public class SSHConsole {
    public enum ProtocolError : Error {
        case invalidChannelType
        case invalidDataType
    }

    public typealias Runner = (_ command:String, _ to:CommandHandler.Output, _ user:String, _ environment:[String:String])->Void
    

    let host : String
    let port : Int
    let hostKeys : [ NIOSSHPrivateKey ]
    let authenticationDelegate : NIOSSHServerUserAuthenticationDelegate
    let group : MultiThreadedEventLoopGroup = .init(numberOfThreads: 1)
    var channel : Channel? = nil
    
    /// Define a new SSHConsole.
    ///
    ///  This is where you bind the host, port, hostKeys, and security policy. You will still need
    ///  to call `listen(handlerType:` to actually start listening.
    ///
    ///  This doesn't do anything except record the parameters.
    ///
    ///  In theory you could have more than one of these and serve diffierent ports differently.
    ///
    /// - Parameters:
    ///   - host: The address to bind. Default is "0.0.0.0" for all interfaces.
    ///   - port: The port to bind. Default is 2222.
    ///   - hostKeys: Your array of host keys. Always pass the same keys to avoid annoying users.
    ///   - passwordDelegate: A delegate to imlement your password policy. Nil disables password authentication. Default is nil.
    ///   - publicKeyDelegate: A delegate to implement your public key policy. Nil disables password authentication. Default is nil.
    ///
    /// - Note: If you don't provide either delegate, no one will be able to authenticate. You can provide both.
    ///
    public init( host:String = "0.0.0.0", port: Int = 2222, hostKeys : [ PrivateKey ], passwordDelegate : SSHPasswordDelegate? = nil, publicKeyDelegate : SSHPublicKeyDelegate? = nil ) {
        
        self.host = host
        self.port = port
        self.hostKeys = hostKeys.map{ $0.key}
        self.authenticationDelegate = AuthenticationDelegate(passwordDelegate: passwordDelegate, publicKeyDelegate: publicKeyDelegate)
    }
    deinit {
        try? group.syncShutdownGracefully()
    }
    
    /// Begin listening for SSH commands.
    ///
    /// Will not return until it has finished its `bind` call to bind the port.
    ///
    /// If it returns without throwing then it is listening. Use the `stop()` method to
    /// stop listening.
    ///
    /// You should not start listening again after stopping. It might work? But I'm not committed to it.
    ///
    /// - Parameter handlerType: Your type for executing commands, e.g. `MyHandler.self`
    /// - Throws: This will throw if it is unable to bind the specified port.
    ///
    public func listen( runner: @escaping Runner ) throws {
        func sshChildChannelInitializer(_ channel: Channel, _ channelType: SSHChannelType) -> EventLoopFuture<Void> {
            switch channelType {
            case .session:
                return channel.pipeline.addHandler( CommandHandler(runner: runner, user: "???") )
            default:
                return channel.eventLoop.makeFailedFuture(ProtocolError.invalidChannelType)
            }
        }
        
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                _ = channel.setOption(ChannelOptions.allowRemoteHalfClosure, value:true)
                return channel.pipeline.addHandlers([NIOSSHHandler(role: .server(.init(hostKeys: self.hostKeys,
                                                                                       userAuthDelegate: self.authenticationDelegate)),
                                                                   allocator: channel.allocator,
                                                                   inboundChildChannelInitializer: sshChildChannelInitializer(_:_:)),
                                                     ErrorHandler()])
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        
        channel = try bootstrap.bind(host: host, port: port).wait()
    }
    
    /// Stop listening for SSH commands
    ///
    /// Use `.stop()` to flush any pending commands and close the sockets.
    ///
    /// - Attention: It is possible someone might have a hung or very slow TCP connection and this
    ///   could take a *long* time. Maybe it should have a *timeout* option.
    ///
    /// - Throws: If the channel's `close` fails there will be a throw. There isn't really anything to do about it.
    ///
    public func stop() throws {
        try channel?.close().wait()
    }
    
    /// This is from the example I started with. It appears to exist just in case something
    /// escapes the SSH channel handler.
    internal final class ErrorHandler: ChannelInboundHandler {
        typealias InboundIn = Any
        
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            print("Error in pipeline: \(error)")
            context.close(promise: nil)
        }
    }
}

extension SSHConsole {
    internal final class AuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate {
        let passwordDelegate : SSHPasswordDelegate?
        let publicKeyDelegate : SSHPublicKeyDelegate?

        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
        
        init( passwordDelegate : SSHPasswordDelegate? = nil, publicKeyDelegate: SSHPublicKeyDelegate? = nil ) {
            self.passwordDelegate = passwordDelegate
            self.publicKeyDelegate = publicKeyDelegate
            
            let pw : NIOSSHAvailableUserAuthenticationMethods = passwordDelegate == nil ? [] : [ .password ]
            let pk : NIOSSHAvailableUserAuthenticationMethods = publicKeyDelegate == nil ? [] : [ .publicKey ]
            supportedAuthenticationMethods = pw.union(pk)
        }
        
        func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            // I don't want to leak NIOSSH to our callers, so we do with a simple Bool callback and keep
            // the promises to ourselves.
            let finish = { (_ b:Bool) -> Void in
                responsePromise.succeed( b ? .success : .failure )
            }
            
            switch request.request {
            case .password(let password):
                guard let d = passwordDelegate else { return responsePromise.succeed(.failure) }
                
                d.authenticate(username: request.username, password: password.password, completion: finish)
            case .publicKey(let pubkey):
                guard let d = publicKeyDelegate else { return responsePromise.succeed(.failure) }
                
                d.authenticate(username: request.username, publicKey:PublicKey(key:pubkey), completion: finish)
            default:
                responsePromise.succeed(.failure)
            }
            
        }
    }
}


extension SSHConsole {
    /// A public key and the methods to deal with it.
    public struct PublicKey {
        let key : NIOSSHUserAuthenticationRequest.Request.PublicKey
        
        /// Create a public key from a NIOSSH PublicKey.
        ///
        /// Should this really be public?
        ///
        /// - Parameter key: The NIOSSH domain key
        ///
        public init(key: NIOSSHUserAuthenticationRequest.Request.PublicKey) {
            self.key = key
        }
        
        /// Compare a public key with an OpenSSH textually formatted key.
        ///
        /// The format looks like???
        /// ```
        /// ssh-ed25519 djh282kjhd929huwqdh92uh9f9h912f9hf optional comment
        /// ```
        ///
        /// RSA keys are *not* supported by NIOSSH
        ///
        /// - Parameter openSSHPublicKey: The OpenSSH formatted key
        /// - Returns: true if the keys are identical
        ///
        public func matches( openSSHPublicKey:String) -> Bool {
            guard let k = try? NIOSSHPublicKey.init(openSSHPublicKey: openSSHPublicKey) else { return false }
            return k == self.key.publicKey
        }
        
        /// Search an entire file of OpenSSH keys for this public key
        ///
        /// You might find such a file in your `~/.ssh/authorized_keys` file. The
        /// Echo example program has code to find and read this file.
        ///
        /// The format looks like???
        /// ```
        /// ssh-ed25519 djh282kjhd929huwqdh92uh9f9h912f9hf optional comment
        /// ```
        ///
        /// RSA keys are *not* supported by NIOSSH
        /// - Parameter file: The String contents of the file
        /// - Returns: true if the key is present in the file
        ///
        public func isIn( file:String) -> Bool {
            return file.split(separator: "\n")
                .map{ $0.trimmingCharacters(in: .whitespacesAndNewlines)}
                .contains { self.matches(openSSHPublicKey: $0) }
        }
    }
    
    /// A private key and the methods to deal with it.
    ///
    /// This is primarily papering over a deficiency in the NIOSSH API which makes their
    /// private key so opaque we can't get a representation to save when we make a new one.
    ///
    /// Someday most of this should go away.
    ///
    public struct PrivateKey {
        var key : NIOSSHPrivateKey { NIOSSHPrivateKey(ed25519Key: _key) }
        
        ///
        /// Return a string representation of the private key. Used to store a newly generated
        /// host key for later use.
        ///
        public var string : String { "ed25519 \(_key.rawRepresentation.base64EncodedString())" }
        
        private let _key : Curve25519.Signing.PrivateKey
        
        /// Create a new private key.
        ///
        /// You will want to do this once for your server on a given host, then save it someplace
        /// beyond prying eyes. Anyone that gets your host key and can orchestrate a MITM
        /// attack will succeed.
        ///
        public init() {
            _key = Curve25519.Signing.PrivateKey()
        }
        
        /// Create a private key from its string representation.
        ///
        /// - Note: Only ed25519 is currently supported. It will take about 20 lines of code to
        /// add the other formats supported by NIOSSH if needed.
        ///
        /// - Parameter string: Looks like `"ed25519 asdjhskh2u8huf optional comment"`
        ///
        public init?( string:String) {
            let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            
            if parts.count < 2 { return nil }

            guard let data = Data( base64Encoded:String(parts[1])) else { return nil }

            switch parts[0] {
            case "ed25519":
                guard let hk = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
                _key = hk
            default:
                return nil
            }
        }
    }

}
