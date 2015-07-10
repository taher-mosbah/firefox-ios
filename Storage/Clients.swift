/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared

public struct RemoteClient: Equatable {
    public let guid: GUID?
    public let modified: Timestamp

    public let name: String
    public let type: String?
    public let commands: [SyncCommand]?

    let version: String?
    let protocols: [String]?

    let os: String?
    let appPackage: String?
    let application: String?
    let formfactor: String?
    let device: String?

    // Requires a valid ClientPayload (: CleartextPayloadJSON: JSON).
    public init(json: JSON, modified: Timestamp) {
        self.guid = json["id"].asString!
        self.modified = modified
        self.name = json["name"].asString!
        self.type = json["type"].asString

        self.version = json["version"].asString
        self.protocols = jsonsToStrings(json["protocols"].asArray)
        self.os = json["os"].asString
        self.appPackage = json["appPackage"].asString
        self.application = json["application"].asString
        self.formfactor = json["formfactor"].asString
        self.device = json["device"].asString
        self.commands = nil
    }

    public init(guid: GUID?, name: String, modified: Timestamp, type: String?, formfactor: String?, os: String?) {
        self.guid = guid
        self.name = name
        self.modified = modified
        self.type = type
        self.formfactor = formfactor
        self.os = os

        self.device = nil
        self.appPackage = nil
        self.application = nil
        self.version = nil
        self.protocols = nil
        self.commands = nil
    }

    public init(client: RemoteClient, withCommands commands: [SyncCommand]) {
        self.guid = client.guid
        self.name = client.name
        self.modified = client.modified
        self.type = client.type
        self.formfactor = client.formfactor
        self.os = client.os

        self.device = client.device
        self.appPackage = client.appPackage
        self.application = client.application
        self.version = client.version
        self.protocols = client.protocols
        self.commands = commands
    }

    func withCommands(commands: [SyncCommand]) -> RemoteClient {
        return RemoteClient(client: self, withCommands: commands)
    }

    public func toJSON() -> JSON {
        var jsonCommands: [JSON]
        if let cmds = self.commands {
            jsonCommands = cmds.map { command in
                JSON(command.value)
            }
        } else {
            jsonCommands = [JSON]()
        }
        let jsonFormFactor = formfactor ?? ""
        let jsonDevice = device ?? ""
        let jsonAppPackage = appPackage ?? ""
        let jsonApplication = application ?? ""
        let jsonVersion = version ?? ""
        let jsonProtocols = protocols ?? [] 

        let json = JSON([
            "id": guid ?? "",
            "version": jsonVersion,    // TODO
            "protocols": jsonProtocols,
            "name": name,
            "os": os ?? "iOS",
            "commands": jsonCommands,
            "type": type ?? "mobile",
            "appPackage":  jsonAppPackage,
            "application": jsonApplication,
            "device": jsonDevice,
            "formfactor": jsonFormFactor,
            ])
        return json
    }
}

// TODO: should this really compare tabs?
public func ==(lhs: RemoteClient, rhs: RemoteClient) -> Bool {
    return lhs.guid == rhs.guid &&
        lhs.name == rhs.name &&
        lhs.modified == rhs.modified &&
        lhs.type == rhs.type &&
        lhs.formfactor == rhs.formfactor &&
        lhs.os == rhs.os
}

extension RemoteClient: Printable {
    public var description: String {
        return "<RemoteClient GUID: \(guid), name: \(name), modified: \(modified), type: \(type), formfactor: \(formfactor), OS: \(os)>"
    }
}