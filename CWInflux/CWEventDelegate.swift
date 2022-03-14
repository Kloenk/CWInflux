//
//  CWEventDelegate.swift
//  CWInflux
//
//  Created by Finn Behrens on 14.03.22.
//

import AppKit
import CoreWLAN
import Foundation
import InfluxDBSwift
import os

actor CWInflux {
    var wifi: CWWiFiClient

    var bucket: String
    var org: String
    var token: String
    var url: String

    static var logger = Logger(subsystem: "dev.kloenk.CWInflux", category: "wifi-influx")
    var newPoints: [InfluxDBClient.Point] = []
    var scheduled = false
    // var timer: Timer = Timer()
    static var queue = DispatchQueue(label: "dev.kloenk.CWInflux", qos: .background, attributes: .concurrent)

    public init(bucket: String, org: String, token: String, url: String) async throws {
        wifi = CWWiFiClient.shared()

        self.bucket = bucket
        self.org = org
        self.token = token
        self.url = url

        wifi.delegate = self

        await sync()

        try wifi.startMonitoringEvent(with: .powerDidChange)
        try wifi.startMonitoringEvent(with: .ssidDidChange)
        try wifi.startMonitoringEvent(with: .bssidDidChange)
        try wifi.startMonitoringEvent(with: .countryCodeDidChange)
        try wifi.startMonitoringEvent(with: .linkDidChange)
        try wifi.startMonitoringEvent(with: .linkQualityDidChange)
        try wifi.startMonitoringEvent(with: .modeDidChange)
        // try wifi.startMonitoringEvent(with: .scanCacheUpdated)
    }

    func sync() async {
        guard let interfaces = wifi.interfaces() else {
            // TODO: error
            return
        }

        do {
            var points = try interfaces.map { try parseInterface(interface: $0) }
            CWInflux.logger.debug("collected sync data")

            points.append(contentsOf: newPoints)
            try await flush(points: points)
            CWInflux.logger.debug("send sync data")
            newPoints = []
        } catch {
            CWInflux.logger.warning("failed to sync: \(error.localizedDescription)")
        }

        CWInflux.queue.schedule(after: .init(.now().advanced(by: .seconds(60))), tolerance: .seconds(20)) {
            Task(priority: .background) {
                await self.sync()
            }
        }
    }

    func flush() async {
        CWInflux.logger.debug("flushing")
        scheduled = false
        do {
            try await flush(points: newPoints)
            CWInflux.logger.debug("wrote \(self.newPoints.count) data points")
            newPoints = []
        } catch {
            CWInflux.logger.warning("Failed to write points: \(error.localizedDescription)")
            schedule()
        }
    }

    func flush(points: [InfluxDBClient.Point]) async throws {
        let client = InfluxDBClient(
            url: url,
            token: token,
            options: InfluxDBClient.InfluxDBOptions(bucket: bucket, org: org)
        )

        CWInflux.logger.info("writing \(points.count) data points")
        /* for point in points {
             try await client.makeWriteAPI().write(point: point, responseQueue: CWInflux.queue)
         } */
        try await client.makeWriteAPI().write(points: points)

        client.close()
        await URLSession.shared.flush()
    }

    func schedule() {
        if !scheduled {
            CWInflux.queue.schedule(after: .init(.now().advanced(by: .seconds(20))), tolerance: .seconds(10)) {
                Task(priority: .background) {
                    await self.flush()
                }
            }
        }
        scheduled = true
    }

    func addPoint(_ point: InfluxDBClient.Point) {
        newPoints.append(point)
        schedule()
    }

    func createPoint(name: String) -> InfluxDBClient.Point {
        InfluxDBClient.Point("cw_wifi")
            .addTag(key: "interface", value: name)
    }

    func parseInterface(interface: CWInterface) throws -> InfluxDBClient.Point {
        guard let name = interface.interfaceName else {
            // TODO: what to do when we have no name
            throw CWInfluxError.noInterfaceName
        }

        let point = createPoint(name: name)

        point.addField(key: "power", value: .boolean(interface.powerOn()))
        point.addField(key: "tx_power", value: .int(interface.transmitPower()))
        point.addField(key: "tx_rate", value: .double(interface.transmitRate()))
        if let ssid = interface.ssid() {
            point.addField(key: "ssid", value: .string(ssid))
        }
        if let bssid = interface.bssid() {
            point.addField(key: "bssid", value: .string(bssid))
        }
        if let code = interface.countryCode() {
            point.addField(key: "country_code", value: .string(code))
        }
        if let hwAddr = interface.hardwareAddress() {
            point.addField(key: "hw_address", value: .string(hwAddr))
        }

        point.addField(key: "noise", value: .int(interface.noiseMeasurement()))
        point.addField(key: "rssi", value: .int(interface.rssiValue()))
        point.addField(key: "security", value: .int(interface.security().rawValue))

        point.addField(key: "if_mode", value: .int(interface.interfaceMode().rawValue))
        point.addField(key: "phy_mode", value: .int(interface.activePHYMode().rawValue))

        return point
    }
}

extension CWInflux: CWEventDelegate {
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName) else {
                return
            }

            CWInflux.logger.debug("power changed to \(interface.powerOn())")

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "power", value: .boolean(interface.powerOn()))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName),
                  let ssid = interface.ssid()
            else {
                return
            }

            CWInflux.logger.debug("ssid changed to '\(ssid)'")

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "ssid", value: .string(ssid))
            point.addField(key: "security", value: .int(interface.security().rawValue))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName),
                  let bssid = interface.bssid()
            else {
                return
            }

            CWInflux.logger.debug("bssid changed to '\(bssid)'")

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "bssid", value: .string(bssid))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func countryCodeDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName),
                  let countryCode = interface.countryCode()
            else {
                return
            }

            CWInflux.logger.debug("country code changed to \(countryCode)")

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "country_code", value: .string(countryCode))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName) else {
                return
            }

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "if_mode", value: .int(interface.interfaceMode().rawValue))
            point.addField(key: "phy_mode", value: .int(interface.activePHYMode().rawValue))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        Task(priority: .background) {
            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "tx_rate", value: .double(transmitRate))
            point.addField(key: "rssi", value: .int(rssi))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func modeDidChangeForWiFiInterface(withName interfaceName: String) {
        Task(priority: .background) {
            guard let interface = await self.wifi.interface(withName: interfaceName) else {
                return
            }

            let point = await self.createPoint(name: interfaceName)
            point.addField(key: "if_mode", value: .int(interface.interfaceMode().rawValue))
            point.addField(key: "phy_mode", value: .int(interface.activePHYMode().rawValue))
            point.time(time: Date())

            await self.addPoint(point)
        }
    }

    nonisolated func clientConnectionInterrupted() {
        CWInflux.logger.warning("Connection to wifi subsystem interrupted.")
    }

    nonisolated func clientConnectionInvalidated() {
        Task(priority: .background) {
            CWInflux.logger.error("Connection to wifi subsystem ended.")
            await NSApplication.shared.stop(self)
        }
    }
}
