/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
import Shared

public struct ClientSyncCommands:Equatable {
    public let client: GUID
    public var commands: [SyncCommand]

    public var description: String {
        return "<Client \(client), \(commands) commands.>"
    }

    public init(client: GUID, commands: [SyncCommand]) {
        self.client = client
        self.commands = commands
    }

    public func toJSON() -> [JSON] {
        return commands.map { command in
            return JSON(command.value)
        }
    }
}

public func ==(lhs: ClientSyncCommands, rhs: ClientSyncCommands) -> Bool {
    return (lhs.client == rhs.client)
}

public struct SyncCommand: Equatable {
    public let value: String
    public var commandID: Int?
    public let clientGUID: GUID?

    let version: String?

    public init(value: String) {
        self.value = value
        self.version = nil
        self.commandID = nil
        self.clientGUID = nil
    }

    public init(id: Int, value: String) {
        self.value = value
        self.version = nil
        self.commandID = id
        self.clientGUID = nil
    }

    public init(id: Int?, value: String, clientGUID: GUID?) {
        self.value = value
        self.version = nil
        self.clientGUID = clientGUID
        self.commandID = id
    }


    public static func fromShareItem(shareItem: ShareItem, withAction action: String) -> SyncCommand {
        let jsonObj:[String: AnyObject] = [
            "command": action,
            "args": [shareItem.url, shareItem.title ?? ""]
        ]
        return SyncCommand(value: JSON.stringify(jsonObj, pretty: false))
    }

    public func withClientGUID(clientGUID: String?) -> SyncCommand {
        return SyncCommand(id: self.commandID, value: self.value, clientGUID: clientGUID)
    }
}

public func ==(lhs: SyncCommand, rhs: SyncCommand) -> Bool {
    return lhs.value == rhs.value
}

public struct ClientSyncCommand:Equatable {
    public let clientSyncID: Int?
    public let clientGUID: GUID
    public let commandID: Int?

    public var description: String {
        return "<Client \(clientGUID), \(commandID) command.>"
    }

    public init(clientSyncID: Int?, clientGUID: String, commandID:Int?) {
        self.clientGUID = clientGUID
        self.commandID = commandID
        self.clientSyncID = clientSyncID
    }
}

public func ==(lhs: ClientSyncCommand, rhs: ClientSyncCommand) -> Bool {
    return (lhs.clientGUID == rhs.clientGUID) &&
        (lhs.commandID == rhs.commandID)
}

public protocol SyncCommands {
    func deleteCommands() -> Success
    func deleteCommands(clientCommands: ClientSyncCommands) -> Success

    func getCommands() -> Deferred<Result<[ClientSyncCommands]>>
    func getCommandsForClient(clientGUID: GUID) -> Deferred<Result<ClientSyncCommands>>

    func insertCommand(command: SyncCommand, forClients clients: [RemoteClient]) -> Deferred<Result<Int>>
    func insertCommands(commands: [SyncCommand], forClients clients: [RemoteClient]) -> Deferred<Result<Int>>
}