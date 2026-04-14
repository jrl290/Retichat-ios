//
//  DefaultEndpointManager.swift
//  Retichat
//
//  Shuffled default TCP endpoints matching the Android app.
//

import Foundation

struct DefaultEndpointManager {
    static let endpoints: [(host: String, port: Int)] = [
        ("162.19.248.199", 4242),
        ("193.26.158.230", 4965),
        ("213.235.65.180", 4440),
        ("213.89.12.80", 4242),
        ("217.154.184.223", 45823),
        ("217.70.19.114", 4242),
        ("23.188.56.190", 9050),
        ("37.193.84.9", 4242),
        ("37.221.212.76", 4242),
        ("45.59.114.96", 7822),
        ("45.77.109.86", 4965),
        ("62.151.179.77", 45657),
        ("62.183.96.32", 4242),
        ("75.133.206.221", 4242),
        ("77.221.159.41", 4242),
        ("77.37.166.237", 4242),
        ("82.165.27.170", 443),
        ("82.22.20.33", 9500),
        ("82.223.44.241", 4242),
        ("87.106.8.245", 4242),
        ("91.207.113.250", 4242),
        ("93.40.0.250", 4242),
        ("93.95.227.8", 49952),
        ("94.180.116.248", 4242),
        ("aspark.uber.space", 44860),
        ("dfw.us.g00n.cloud", 6969),
        ("intr.cx", 4242),
        ("istanbul.reserve.network", 9034),
        ("phantom.mobilefabrik.com", 4242),
        ("reticulum.betweentheborders.com", 4242),
        ("reticulum.lazynoda.es", 4242),
        ("rmap.world", 4242),
        ("rns.beleth.net", 4242),
        ("rns.derps.me", 34242),
        ("rns.dismail.de", 7822),
        ("rns.michmesh.net", 7822),
        ("rns.nittedal.town", 4242),
        ("rns.noderage.org", 4242),
        ("rns.one-big.network", 4242),
        ("rns.pawgslayers.club", 4242),
        ("rns.simplyequipped.com", 4242),
        ("rns.soon.it", 4242),
        ("rns.stoppedcold.com", 4242),
        ("rns.wiegandtech.net", 4242),
        ("rns.yggdrasil.michmesh.net", 7822),
        ("rns01.powerglitch.ro", 4242),
        ("sydney.reticulum.au", 4242),
        ("vjs.hu", 5858),
        ("vps001.vanheusden.com", 4242),
        ("world.reticulum.is", 3400),
    ]

    /// Return a shuffled copy of the endpoint list.
    static func shuffled() -> [(host: String, port: Int)] {
        return endpoints.shuffled()
    }

    /// Pick the first endpoint, rotating from a shuffled copy.
    static func pick() -> (host: String, port: Int) {
        return endpoints.randomElement() ?? endpoints[0]
    }
}
