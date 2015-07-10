/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import XCTest


func byValue(a: SyncCommand, b: SyncCommand) -> Bool {
    return a.value < b.value
}

func byClient(a: ClientSyncCommands, b: ClientSyncCommands) -> Bool{
    return a.client < b.client
}

class SyncCommandsTests: XCTestCase {


    var clients: [RemoteClient] = [RemoteClient]()
    var clientsAndTabs: SQLiteRemoteClientsAndTabs!

    var shareItems = [ShareItem]()

    var multipleCommands: [ShareItem] = [ShareItem]()
    var wipeCommand: SyncCommand!
    var db: BrowserDB!

    override func setUp() {
        let files = MockFiles()
        files.remove("browser.db")
        db = BrowserDB(filename: "browser.db", files: files)
        // create clients

        let now = NSDate.now()
        let client1GUID = Bytes.generateGUID()
        let client2GUID = Bytes.generateGUID()
        let client3GUID = Bytes.generateGUID()

        self.clients.append(RemoteClient(guid: client1GUID, name: "Test client 1", modified: (now - OneMinuteInMilliseconds), type: "mobile", formfactor: "largetablet", os: "iOS"))
        self.clients.append(RemoteClient(guid: client2GUID, name: "Test client 2", modified: (now - OneHourInMilliseconds), type: "desktop", formfactor: "laptop", os: "Darwin"))
        self.clients.append(RemoteClient(guid: client3GUID, name: "Test local client", modified: (now - OneMinuteInMilliseconds), type: "mobile", formfactor: "largetablet", os: "iOS"))
        clientsAndTabs = SQLiteRemoteClientsAndTabs(db: db)
        clientsAndTabs.insertOrUpdateClients(clients)

        shareItems.append(ShareItem(url: "http://mozilla.com", title: "Mozilla", favicon: nil))
        shareItems.append(ShareItem(url: "http://slashdot.org", title: "Slashdot", favicon: nil))
        shareItems.append(ShareItem(url: "http://news.bbc.co.uk", title: "BBC News", favicon: nil))
        shareItems.append(ShareItem(url: "http://news.bbc.co.uk", title: nil, favicon: nil))

        wipeCommand = SyncCommand(value: "{'command':'wipeAll', 'args':[]}")
    }

    override func tearDown() {
        clientsAndTabs.deleteCommands()
        clientsAndTabs.clear()
    }

    func testCreateSyncCommandFromShareItem(){
        let action = "testcommand"
        let shareItem = shareItems[0]
        let syncCommand = SyncCommand.fromShareItem(shareItem, withAction: action)
        XCTAssertNil(syncCommand.commandID)
        XCTAssertNotNil(syncCommand.value)
        let jsonObj:[String: AnyObject] = [
            "command": action,
            "args": [shareItem.url, shareItem.title ?? ""]
        ]
        XCTAssertEqual(JSON.stringify(jsonObj, pretty: false), syncCommand.value)
    }

    func testInsertWithNoURLORTitle() {
        // Test insert command to table for
        let e = self.expectationWithDescription("Insert.")
        clientsAndTabs.insertCommand(self.wipeCommand, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(3, $0.successValue!)

            var error: NSError? = nil
            let clientCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableClientCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error)
            XCTAssertNotNil(clientCursor[0])
            XCTAssertEqual(3, clientCursor[0]!)

            var error2: NSError? = nil
            let commandCursor = self.db.withReadableConnection(&error2) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableSyncCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error2)
            XCTAssertNotNil(commandCursor[0])
            XCTAssertEqual(1, commandCursor[0]!)
            e.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    func testInsertWithURLOnly() {
        let action = "testcommand"
        let shareItem = shareItems[3]
        let syncCommand = SyncCommand.fromShareItem(shareItem, withAction: action)

        let e = self.expectationWithDescription("Insert.")
        clientsAndTabs.insertCommand(syncCommand, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(3, $0.successValue!)

            var error: NSError? = nil
            let commandCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableSyncCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error)
            XCTAssertNotNil(commandCursor[0])
            XCTAssertEqual(1, commandCursor[0]!)
            e.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    func testInsertWithMultipleCommands() {
        let action = "testcommand"
        let e = self.expectationWithDescription("Insert.")
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
        }
        clientsAndTabs.insertCommands(syncCommands, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(12, $0.successValue!)

            var error: NSError? = nil
            let commandCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableSyncCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error)
            XCTAssertNotNil(commandCursor[0])
            XCTAssertEqual(4, commandCursor[0]!)
            e.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    func testGetForValidClient() {
        let action = "testcommand"
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
        }.sorted(byValue)
        let e = self.expectationWithDescription("Insert.")
        let a = self.expectationWithDescription("Get for client.")
        let b = self.expectationWithDescription("Get for client 1.")
        clientsAndTabs.insertCommands(syncCommands, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(12, $0.successValue!)

            var error: NSError? = nil
            let clientCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableClientCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error)
            XCTAssertNotNil(clientCursor[0])
            XCTAssertEqual(12, clientCursor[0]!)

            var error2: NSError? = nil
            let commandCursor = self.db.withReadableConnection(&error2) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableSyncCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error2)
            XCTAssertNotNil(commandCursor[0])
            XCTAssertEqual(4, commandCursor[0]!)
            e.fulfill()

            // add in an extra command for a client we are not testing for
            self.clientsAndTabs.insertCommand(self.wipeCommand, forClients: [self.clients[1]])

            var client = self.clients[0]
            self.clientsAndTabs.getCommandsForClient(client.guid!).upon({ result in
                if let clientCommands = result.successValue {
                    XCTAssertEqual(syncCommands, clientCommands.commands.sorted(byValue))
                } else {
                    XCTFail("Expected commands!")
                }
                a.fulfill()
            })

            client = self.clients[1]
            self.clientsAndTabs.getCommandsForClient(client.guid!).upon({ result in
                if let clientCommands = result.successValue {
                    XCTAssertEqual((syncCommands + [self.wipeCommand]).sorted(byValue), clientCommands.commands.sorted(byValue))
                } else {
                    XCTFail("Expected commands!")
                }
                b.fulfill()
            })
        }

        self.waitForExpectationsWithTimeout(10, handler: nil)
    }

    func testGetForInvalidClient() {
        let action = "testcommand"
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
            }.sorted(byValue)
        clientsAndTabs.insertCommands(syncCommands, forClients: clients)

        let b = self.expectationWithDescription("Get for invalid client.")
        clientsAndTabs.getCommandsForClient(Bytes.generateGUID()).upon({ result in
            XCTAssertTrue(result.isSuccess)
            if let clientCommands = result.successValue {
                XCTAssertEqual([], clientCommands.commands)
            } else {
                XCTFail("Expected commands!")
            }
            b.fulfill()
        })
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    func testGetForAllClients() {
        let action = "testcommand"
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
        }.sorted(byValue)
        clientsAndTabs.insertCommands(syncCommands, forClients: clients)

        let b = self.expectationWithDescription("Get for invalid client.")
        clientsAndTabs.getCommands().upon({ result in
            XCTAssertTrue(result.isSuccess)
            if let clientCommands = result.successValue {
                XCTAssertEqual(clientCommands.count, self.clients.count)
                for cmd in clientCommands {
                    XCTAssertEqual(syncCommands, cmd.commands.sorted(byValue))
                }
            } else {
                XCTFail("Expected no commands!")
            }
            b.fulfill()
        })
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    func testDeleteForValidClient() {
        let action = "testcommand"
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
        }.sorted(byValue)

        var client = self.clients[0]
        let a = self.expectationWithDescription("delete for client.")
        let b = self.expectationWithDescription("Get for deleted client.")
        let c = self.expectationWithDescription("Get for not deleted client.")
        let commandsToDelete = ClientSyncCommands(client: client.guid!, commands: syncCommands)
        clientsAndTabs.insertCommands(syncCommands, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(12, $0.successValue!)

            var error: NSError? = nil
            let clientCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                let select = "SELECT COUNT(*) FROM \(TableClientCommands)"
                return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
            }
            XCTAssertNil(error)
            XCTAssertNotNil(clientCursor[0])
            XCTAssertEqual(12, clientCursor[0]!)

            self.clientsAndTabs.deleteCommands(commandsToDelete).upon({ result in
                XCTAssertTrue(result.isSuccess)
                a.fulfill()

                self.clientsAndTabs.getCommandsForClient(client.guid!).upon({ result in
                    XCTAssertTrue(result.isSuccess)
                    if let clientCommands = result.successValue {
                        XCTAssertEqual(0, clientCommands.commands.count)
                    } else {
                        XCTFail("Expected no commands!")
                    }
                    b.fulfill()
                })

                var error: NSError? = nil
                let clientCursor = self.db.withReadableConnection(&error) { (connection, err) -> Cursor<Int> in
                    let select = "SELECT COUNT(*) FROM \(TableClientCommands)"
                    return connection.executeQuery(select, factory: IntFactory, withArgs: nil)
                }
                XCTAssertNil(error)
                XCTAssertNotNil(clientCursor[0])
                XCTAssertEqual(8, clientCursor[0]!)

                client = self.clients[1]
                self.clientsAndTabs.getCommands().upon({ result in
                    XCTAssertTrue(result.isSuccess)
                    if let clientCommands = result.successValue {
                        XCTAssertEqual(clientCommands.count, 2)
                    } else {
                        XCTFail("Expected commands!")
                    }
                    c.fulfill()
                })
            })
        }

        self.waitForExpectationsWithTimeout(5, handler: nil)
    }

    // I have no idea why this test is failing??????????Remo
    func testDeleteForAllClients() {
        let action = "testcommand"
        let syncCommands = shareItems.map { item in
            return SyncCommand.fromShareItem(item, withAction: action)
        }

        let a = self.expectationWithDescription("Wipe for all clients.")
        let b = self.expectationWithDescription("Get for clients.")
        clientsAndTabs.insertCommands(syncCommands, forClients: clients).upon {
            XCTAssertTrue($0.isSuccess)
            XCTAssertEqual(12, $0.successValue!)

            self.clientsAndTabs.deleteCommands().upon({ result in
                XCTAssertTrue(result.isSuccess)
                a.fulfill()

                self.clientsAndTabs.getCommands().upon({ result in
                    XCTAssertTrue(result.isSuccess)
                    if let clientCommands = result.successValue {
                        XCTAssertEqual([], clientCommands)
                    } else {
                        XCTFail("Expected no commands!")
                    }
                    b.fulfill()
                })
            })
        }
        
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
}