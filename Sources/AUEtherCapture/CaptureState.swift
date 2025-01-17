//
//  File.swift
//  
//
//  Created by user on 2021/03/01.
//

import Foundation
import BinaryReader
import SwiftMsgPack
import Gzip

struct Ack: Hashable {
    var pair: UDPPair
    var no: UInt16
}

struct CaptureState {
    var ackStore = Set<Ack>()
    var callAfterFinishCurrentPacket = [() -> Void]()
    var timestamp: Double = 0
    var gameState = GameState() {
        didSet {
            if gameState.clientVersion != clientVersion {
                gameState.clientVersion = clientVersion
            }
        }
    }
    var outDir: URL?
    var muteProxyURL: URL?
    var discordWebhookURL: URL?
    var clientVersion: Int32 = 0 {
        didSet {
            gameState.clientVersion = clientVersion
        }
    }
    
    mutating func setDiscordWebhook(key: String) throws {
        typealias Webhooks = [String: URL]
        let data = try Data(contentsOf: CONFIG_DIR_URL.appendingPathComponent("webhooks.json"))
        let webhooks = try JSONDecoder().decode(Webhooks.self, from: data)
        guard let url = webhooks[key] else {
            fatalError("specified webhook does not recognized")
        }
        discordWebhookURL = url
    }

    mutating func handleACK(ack: Ack) -> Bool {
        if ackStore.contains(ack) {
            return false
        }
        ackStore.insert(ack)
        return true
    }
    
    mutating func handle(data: Data, pair: UDPPair) {
        guard let packet = AURootPacket(data: data) else {
            print(data.map { String(format: "%02X", $0) }.joined())
            return
        }
        defer {
            while let fn = callAfterFinishCurrentPacket.popLast() {
                fn()
            }
        }
        switch packet {
        case .reliable(let ack, let packets):
            guard handleACK(ack: .init(pair: pair, no: ack)) else {
                break
            }
            fallthrough
        case .normal(let packets):
            for packet in packets {
                handleHazel(packet: packet)
            }
        case .hello(let ack, hazelVersion: let hazelVersion, clientVersion: let clientVersion, name: let name):
            guard handleACK(ack: .init(pair: pair, no: ack)) else {
                break
            }
            if clientVersion > (3000 * 25000) {
                fatalError("Client Version is TOO BIG (maybe endian mismatching?): \(clientVersion)")
            }
            if clientVersion < (2000 * 25000) {
                fatalError("Client Version is TOO SMALL (maybe endian mismatching?): \(clientVersion)")
            }
            self.clientVersion = clientVersion
            print(packet)
        case .disconnect(forced: let forced, reason: let reason, description: let description):
            fallthrough
        case .disconnectSimple:
            updateAutoMuteUsScene(scene: .menu)
        case .ack(let ack):
            for ack in ack {
                let ack = Ack(pair: pair.reversed(), no: ack)
                if !ackStore.contains(ack) {
                    print("ACK BUT NOT RECEIVED", ack.no)
                }
                ackStore.remove(ack)
            }
        case .ping(let ack):
            _ = handleACK(ack: .init(pair: pair, no: ack))
        default:
            print("Root", packet)
        }
    }
    
    mutating func handleHazel(packet: AUHazelPacket) {
        var reader = BinaryReader(data: packet.data)
        switch RootHazelPacketType(rawValue: packet.type) {
        case .gameData:
            let id = reader.int32()
            gameState.id = .init(rawValue: id)
            handleGameDataArray(&reader)
        case .gameDataTo:
            let id = reader.int32()
            let targetID = reader.packedInt32()
            gameState.id = .init(rawValue: id)
            handleGameDataArray(&reader)
        case .joinedGame:
            print("Reset State")
            for player in gameState.players.values {
                updateAutoMuteUsPlayer(player: player, action: .left)
            }
            gameState = .init()
            updateAutoMuteUsScene(scene: .lobby)
        case .endGame: // EndGame
            _ = reader.int32()
            let reason = EndReason(rawValue: reader.uint8())
            guard gameState.startedAt > 0 else {
                break
            }
            gameState.endReason = reason
            gameState.duration = timestamp - gameState.startedAt
            gameFinish()
        default:
            print("Hazel", packet)
        }
    }
    
    mutating func gameFinish() {
        do {
            let dat = try data()
            if let outDir = outDir {
                dat.output(to: outDir)
            }
            try dat.upload(discordWebhookURL: discordWebhookURL)
        } catch {
            print("Error (relaed to result data)", error)
        }
        updateAutoMuteUsScene(scene: .ended)
        updateAutoMuteUsGameOver(reason: gameState.endReason!, players: Array(gameState.players.values))
        sleep(1)
        for player in gameState.players.values {
            updateAutoMuteUsPlayer(player: player, action: .left)
        }
        gameState = .init()
    }
    
    mutating func handleGameDataArray(_ reader: inout BinaryReader) {
        while reader.hasMoreData {
            let hazel = AUHazelPacket(from: &reader)
            handleGameData(hazel)
        }
    }
    
    mutating func handleGameData(_ packet: AUHazelPacket) {
        var reader = BinaryReader(data: packet.data)
        switch GameDataType(rawValue: packet.type) {
        case .data: // Data
            let senderID = reader.packedUInt32()
            guard let obj = gameState.components[senderID]?.obj else {
                break
            }
            switch obj.spawnType {
            case .playerControl:
                guard let playerID = obj.playerID else {
                    break
                }
                let move = PlayerMove(
                    type: .normal,
                    sequence: reader.uint16(),
                    playerID: playerID,
                    timestamp: timestamp - gameState.startedAt,
                    position: .init(from: &reader, clientVersion: clientVersion),
                    velocity: .init(from: &reader, clientVersion: clientVersion)
                )
                gameState.moves.append(move)
            case .gameData:
                while reader.hasMoreData {
                    let player = Player(from: &reader, update: true)
                    if let oldPlayer = gameState.players[player.id] {
                        if player.shouldNotifyToAutoMuteUs(old: oldPlayer) {
                            updateAutoMuteUsPlayer(player: player, action: .forceUpdated)
                        }
                    } else {
                        updateAutoMuteUsPlayer(player: player, action: .joined)
                    }
                    gameState.add(player: player)
                }
            default:
                print("Data", obj.spawnType)
            }
            break
        case .rpc: // RPC
            let sender = reader.packedUInt32()
            let rpcType = reader.uint8()
            handleRPC(senderID: sender, rpcType: rpcType, reader: &reader)
        case .spawn: // Spawn
            var obj = InnerNetObject(
                spawnType: reader.packedUInt32(),
                ownerID: reader.packedInt32(),
                spawnFlag: reader.uint8()
            )
            let componentsLength = reader.packedUInt32()
            for i in 0..<componentsLength {
                obj.components.append(.init(netID: reader.packedUInt32(), obj: obj, spawnData: AUHazelPacket(from: &reader).data))
            }
            gameState.add(object: obj)
            switch obj.spawnType {
            case .gameData: // GameData
                let data = obj.components[0].spawnData
                var reader = BinaryReader(data: data)
                let playersLength = reader.packedUInt32()
                for _ in 0..<playersLength {
                    let player = Player(from: &reader, update: false)
                    gameState.add(player: player)
                    updateAutoMuteUsPlayer(player: player, action: .joined)
                }
                print(gameState.players)
                print(obj.components)
            default:
                print("Spawning", obj.spawnType)
            }
        case .despawn:
            let netid = reader.packedUInt32()
            guard let obj = gameState.components[netid]?.obj else {
                break
            }
            if let playerID = obj.playerID, gameState.startedAt == 0, let player = gameState.players[playerID] {
                updateAutoMuteUsPlayer(player: player, action: .left)
            }
            guard let playerID = obj.playerID, gameState.startedAt != 0 else {
                gameState.remove(object: obj)
                break
            }
            guard let player = gameState.players[playerID], player.disconnectedAt == nil else {
                break
            }
            print("disconnected", playerID)
            let timestamp = self.timestamp - gameState.startedAt
            gameState.modify(playerID: playerID) { player in
                player.disconnectedAt = timestamp
            }
            gameState.add(event: .disconnect(.init(player: playerID, timestamp: timestamp)))
            updateAutoMuteUsPlayer(player: player, action: .disconnected)
        default:
            print("GameData", packet)
        }
    }
}
