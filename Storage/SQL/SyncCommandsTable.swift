/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared

let TableClientCommands = "client_commands"
let TableSyncCommands = "commands"

class ClientCommandsTable<T>: GenericTable<ClientSyncCommand> {
    override var name: String { return TableClientCommands }
    override var version: Int { return 1 }

    override var rows: String { return join(",", [
        "id INTEGER PRIMARY KEY AUTOINCREMENT",
        "client_guid TEXT REFERENCES clients(guid)",
        "command_id INTEGER NOT NULL REFERENCES commands(id)",
        ])
    }

    override func getInsertAndArgs(inout item: ClientSyncCommand) -> (String, [AnyObject?])? {
        return ( "INSERT INTO \(name) (client_guid, command_id) VALUES (?, ?);", [item.clientGUID, item.commandID])
    }

    override func getDeleteAndArgs(inout item: ClientSyncCommand?) -> (String, [AnyObject?])? {
        var sql = "DELETE FROM \(name)"
        var args = [AnyObject?]()
        if let item = item {
            args.append(item.clientGUID)
            sql += " WHERE client_guid = ?"
        }
        sql += ";DELETE FROM \(TableSyncCommands) WHERE id NOT IN(SELECT DISTINCT command_id FROM \(name))"
        return (sql, args)
    }

    override var factory: ((row: SDRow) -> ClientSyncCommand)? {
        return { row -> ClientSyncCommand in
            return ClientSyncCommand(
                clientSyncID: row["id"] as? Int,
                clientGUID: row["client_guid"] as! GUID,
                commandID: row["command_id"] as? Int)
        }
    }

    override func getQueryAndArgs(options: QueryOptions?) -> (String, [AnyObject?])? {
        var args = [AnyObject?]()
        if let filter: AnyObject = options?.filter {
            args.append("%\(filter)%")
            return ("SELECT * FROM \(name) WHERE client_guid IN ?", args)
        }
        return ("SELECT * FROM \(name)", [])
    }
}

class SyncCommandsTable<T>: GenericTable<SyncCommand> {
    override var name: String { return TableSyncCommands }
    override var version: Int { return 1 }

    override var rows: String { return join(",", [
        "id INTEGER PRIMARY KEY AUTOINCREMENT",
        "value TEXT NOT NULL"
        ])
    }


    override func getInsertAndArgs(inout item: SyncCommand) -> (String, [AnyObject?])? {
        var args: [AnyObject?] = [item.value]
        return ("INSERT INTO \(name) (value) VALUES (?)", args)
    }

    override func getDeleteAndArgs(inout item: SyncCommand?) -> (String, [AnyObject?])? {
        if let item = item {
            return ("DELETE FROM \(name) WHERE id = ?", [item.commandID])
        } else {
            return ("DELETE FROM \(name)", [])
        }
    }

    override var factory: ((row: SDRow) -> SyncCommand)? {
        return { row -> SyncCommand in
            return SyncCommand(
                id: row["command_id"] as? Int,
                value: row["value"] as! String,
                clientGUID: row["client_guid"] as? GUID)
        }
    }

    override func getQueryAndArgs(options: QueryOptions?) -> (String, [AnyObject?])? {
        var sql = "SELECT * FROM \(TableClientCommands) INNER JOIN \(name) ON \(TableClientCommands).command_id = \(name).id"
        if let opts = options,
            let filter: AnyObject = options?.filter {
                var args: [AnyObject?] = ["\(filter)"]
            switch opts.filterType {
            case .Guid :
                return (sql + " WHERE \(TableClientCommands).client_guid = ?", args)
            case .Id:
                return (sql + " WHERE \(name).id = ?", args)
            default:
                break
            }
        }
        return (sql, [])
    }
}