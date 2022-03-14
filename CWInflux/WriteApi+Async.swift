//
//  WriteApi+Async.swift
//  CWInflux
//
//  Created by Finn Behrens on 14.03.22.
//

import Foundation
import InfluxDBSwift

public extension WriteAPI {
    func write(points: [InfluxDBClient.Point]) async throws {
        return try await withUnsafeThrowingContinuation { continuation in
            self.write(points: points, completion: { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: result!)
            })
        }
    }

    func write(point: InfluxDBClient.Point, responseQueue: DispatchQueue = .main) async throws {
        return try await withUnsafeThrowingContinuation { continuation in
            self.write(point: point, responseQueue: responseQueue, completion: { res in
                continuation.resume(with: res)
            })
        }
    }
}

public extension InfluxDBClient.Point {
    func time(time: Date) {
        self.time(time: .date(time))
    }
}
