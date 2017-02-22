/*
	Copyright (C) 2016 Apple Inc. All Rights Reserved.
	See LICENSE.txt for this sample’s licensing information
	
	Abstract:
	This file contains the main code for the SimpleTunnel server.
*/

import Foundation

/// Dispatch source to catch and handle SIGINT
//let interruptSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, UInt(SIGINT), 0, dispatch_get_main_queue())
let interruptSignalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

/// Dispatch source to catch and handle SIGTERM
//let termSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, UInt(SIGTERM), 0, dispatch_get_main_queue())
let termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

/// Basic sanity check of the parameters.
guard CommandLine.argc == 3 else {
	print("Usage: \(CommandLine.arguments[0]) <port> <config-file>")
	exit(1)
}

func ignore(_: Int32)  {
}
signal(SIGTERM, ignore)
signal(SIGINT, ignore)

//let portString = Process().arguments![1]
//let configurationPath = Process().arguments![2]
let portString = CommandLine.arguments[1]
let configurationPath = CommandLine.arguments[2]
let networkService: NetService

// Initialize the server.

if !ServerTunnel.initializeWithConfigurationFile(path: configurationPath) {
	exit(1)
}

if let portNumber = Int(portString)  {
	networkService = ServerTunnel.startListeningOnPort(port: Int32(portNumber))
}
else {
	print("Invalid port: \(portString)")
	exit(1)
}

// Set up signal handling.

(interruptSignalSource as! DispatchSource).setEventHandler() {
	networkService.stop()
	return
}
(interruptSignalSource as! DispatchObject).resume()

(termSignalSource as! DispatchSource).setEventHandler() {
	networkService.stop()
	return
}
(termSignalSource as! DispatchObject).resume()

RunLoop.main.run()
