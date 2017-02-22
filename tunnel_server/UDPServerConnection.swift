/*
	Copyright (C) 2016 Apple Inc. All Rights Reserved.
	See LICENSE.txt for this sample’s licensing information
	
	Abstract:
	This file contains the UDPServerConnection class. The UDPServerConnection class handles the encapsulation and decapsulation of datagrams in the server side of the SimpleTunnel tunneling protocol.
*/

import Foundation
import Darwin

/// An object representing the server side of a logical flow of UDP network data in the SimpleTunnel tunneling protocol.
class UDPServerConnection: Connection {

	// MARK: Properties

	/// The address family of the UDP socket.
    var addressFamily: Int32 = AF_UNSPEC

	/// A dispatch source for reading data from the UDP socket.
    var responseSource: DispatchSource?

	// MARK: Initializers
    
    override init(connectionIdentifier: Int, parentTunnel: Tunnel) {
		super.init(connectionIdentifier: connectionIdentifier, parentTunnel: parentTunnel)
    }
    
    deinit {
		if responseSource != nil {
			responseSource!.cancel()
		}
    }

	// MARK: Interface

	/// Convert a sockaddr structure into an IP address string and port.
    func getEndpointFromSocketAddress(socketAddressPointer: UnsafePointer<sockaddr>) -> (host: String, port: Int)? {
		let socketAddress = UnsafePointer<sockaddr>(socketAddressPointer).pointee

		switch Int32(socketAddress.sa_family) {
			case AF_INET:
//				var socketAddressInet = UnsafePointer<sockaddr_in>(socketAddressPointer).pointee
                var socketAddressInet = socketAddressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { (ptr) -> sockaddr_in in
                    return ptr.pointee
                })
				let length = Int(INET_ADDRSTRLEN) + 2
				var buffer = [CChar](repeating: 0, count: length)
				let hostCString = inet_ntop(AF_INET, &socketAddressInet.sin_addr, &buffer, socklen_t(length))
				let port = Int(UInt16(socketAddressInet.sin_port).byteSwapped)
                return (String(cString:hostCString!), port)

			case AF_INET6:
//				var socketAddressInet6 = UnsafePointer<sockaddr_in6>(socketAddressPointer).pointee
                var socketAddressInet6 = socketAddressPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { (ptr) -> sockaddr_in6 in
                    return ptr.pointee
                })
				let length = Int(INET6_ADDRSTRLEN) + 2
				var buffer = [CChar](repeating: 0, count: length)
				let hostCString = inet_ntop(AF_INET6, &socketAddressInet6.sin6_addr, &buffer, socklen_t(length))
				let port = Int(UInt16(socketAddressInet6.sin6_port).byteSwapped)
                return (String(cString:hostCString!), port)

			default:
				return nil
		}
    }

    /// Create a UDP socket
    func createSocketWithAddressFamilyFromAddress(address: String) -> Bool {
		var sin = sockaddr_in()
		var sin6 = sockaddr_in6()
		var newSocket: Int32 = -1

		if address.withCString({ cstring in inet_pton(AF_INET6, cstring, &sin6.sin6_addr) }) == 1 {
			// IPv6 peer.
			newSocket = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
			addressFamily = AF_INET6
		}
		else if address.withCString({ cstring in inet_pton(AF_INET, cstring, &sin.sin_addr) }) == 1 {
			// IPv4 peer.
			newSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
			addressFamily = AF_INET
		}

		guard newSocket > 0 else { return false }

//		guard let newResponseSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, UInt(newSocket), 0, dispatch_get_main_queue()) else {
//			close(newSocket)
//			return false
//		}
        guard let newResponseSource = DispatchSource.makeReadSource(fileDescriptor: newSocket, queue: .main) as? DispatchSource else {
            close(newSocket)
            return false
        }

		newResponseSource.setCancelHandler() {
			simpleTunnelLog("closing udp socket for connection \(self.identifier)")
			let UDPSocket = Int32((newResponseSource as DispatchSourceRead).handle)
			close(UDPSocket)
		}
            
		newResponseSource.setEventHandler() {
			guard let source = self.responseSource else { return }

			var socketAddress = sockaddr_storage()
			var socketAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let response = [UInt8](repeating: 0, count: 4096)
			let UDPSocket = Int32((source as DispatchSourceRead).handle)

			let bytesRead = withUnsafeMutablePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                    recvfrom(UDPSocket, UnsafeMutableRawPointer(mutating: response), response.count, 0, $0, &socketAddressLength)
                })
			}

			guard bytesRead >= 0 else {
				let errorString = String(cString: strerror(errno))
                simpleTunnelLog("recvfrom failed: \(errorString)")
				self.closeConnection(.all)
				return
			}

			guard bytesRead > 0 else {
				simpleTunnelLog("recvfrom returned EOF")
				self.closeConnection(.all)
				return
			}

            guard let endpoint = withUnsafePointer(to: &socketAddress, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                    self.getEndpointFromSocketAddress(socketAddressPointer: $0)
                })
            }) else {
//			guard let endpoint = withUnsafePointer(to: &socketAddress, { self.getEndpointFromSocketAddress(socketAddressPointer: UnsafePointer($0)) }) else {
				simpleTunnelLog("Failed to get the address and port from the socket address received from recvfrom")
				self.closeConnection(.all)
				return
			}

			let responseDatagram = NSData(bytes: UnsafeRawPointer(response), length: bytesRead)
			simpleTunnelLog("UDP connection id \(self.identifier) received = \(bytesRead) bytes from host = \(endpoint.host) port = \(endpoint.port)")
			self.tunnel?.sendDataWithEndPoint(responseDatagram as Data, forConnection: self.identifier, host: endpoint.host, port: endpoint.port)
		}

		newResponseSource.resume()
		responseSource = newResponseSource

		return true
    }

    /// Send a datagram to a given host and port.
    override func sendDataWithEndPoint(_ data: Data, host: String, port: Int) {

		if responseSource == nil {
			guard createSocketWithAddressFamilyFromAddress(address: host) else {
				simpleTunnelLog("UDP ServerConnection initialization failed.")
				return
			}
		}

		guard let source = responseSource else { return }
		let UDPSocket = Int32((source as DispatchSourceRead).handle)
		let sent: Int

		switch addressFamily {
			case AF_INET:
				let serverAddress = SocketAddress()
				guard serverAddress.setFromString(host) else {
					simpleTunnelLog("Failed to convert \(host) into an IPv4 address")
					return
				}
				serverAddress.setPort(port)

				sent = withUnsafePointer(to: &serverAddress.sin) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                        sendto(UDPSocket, data.withUnsafeBytes({UnsafeRawPointer($0)}), data.count, 0, $0, socklen_t(serverAddress.sin.sin_len))
                    })
				}

			case AF_INET6:
				let serverAddress = SocketAddress6()
				guard serverAddress.setFromString(host) else {
					simpleTunnelLog("Failed to convert \(host) into an IPv6 address")
					return
				}
				serverAddress.setPort(port)

				sent = withUnsafePointer(to: &serverAddress.sin6) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                        sendto(UDPSocket, data.withUnsafeBytes({ UnsafeRawPointer($0)}), data.count, 0, $0, socklen_t(serverAddress.sin6.sin6_len))
                    })
				}

			default:
				return
        }

		guard sent > 0 else {
			let errorString = String(cString: strerror(errno))
            simpleTunnelLog("UDP connection id \(identifier) failed to send data to host = \(host) port \(port). error = \(errorString)")
			
			closeConnection(.all)
			return
		}

		if sent == data.count {
			// Success
			simpleTunnelLog("UDP connection id \(identifier) sent \(data.count) bytes to host = \(host) port \(port)")
		}
    }

	/// Close the connection.
	override func closeConnection(_ direction: TunnelConnectionCloseDirection) {
		super.closeConnection(direction)

		if let source = responseSource, isClosedForWrite && isClosedForRead {
			source.cancel()
			responseSource = nil
		}
	}
}





