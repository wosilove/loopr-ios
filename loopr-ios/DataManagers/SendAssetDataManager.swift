//
//  SendCurrentAppWalletDataManager.swift
//  loopr-ios
//
//  Created by xiaoruby on 3/18/18.
//  Copyright © 2018 Loopring. All rights reserved.
//

import Foundation
import Geth

struct GasLimit {
    let type: String
    let gasLimit: Int64
    init(json: JSON) {
        self.type = json["type"].stringValue
        self.gasLimit = json["gasLimit"].int64Value
    }
}

class SendCurrentAppWalletDataManager {
    
    static let shared = SendCurrentAppWalletDataManager()
    
    private var gasLimits: [GasLimit]
    private var nonce: Int64
    private var wethAddress: GethAddress?
    
    private init() {
        self.gasLimits = []
        self.nonce = 0
        self.wethAddress = nil
        self.loadGasLimitsFromJson()
        self.getNonceFromServer()
        self.getWethAddress()
    }
    
    func getWethAddress() {
        var address = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
        if let weth = TokenDataManager.shared.getTokenBySymbol("WETH") {
            address = weth.protocol_value
        }
        var error: NSError? = nil
        self.wethAddress = GethNewAddressFromHex(address, &error)
    }
    
    func getGasLimits() -> [GasLimit] {
        return gasLimits
    }
    
    // TODO: Why we need to load gas_limit from a json file instead of writing as code.
    // load
    func loadGasLimitsFromJson() {
        if let path = Bundle.main.path(forResource: "gas_limit", ofType: "json") {
            let jsonString = try? String(contentsOfFile: path, encoding: String.Encoding.utf8)
            let json = JSON(parseJSON: jsonString!)
            for subJson in json.arrayValue {
                let token = GasLimit(json: subJson)
                gasLimits.append(token)
            }
        }
    }

    func getGasLimitByType(type: String) -> Int64? {
        var gasLimit: Int64? = nil
        for case let gas in gasLimits where gas.type.lowercased() == type.lowercased() {
            gasLimit = gas.gasLimit
            break
        }
        return gasLimit
    }
    
    // The API request teth_getTransactionCount is slow. Please be patient. It takes 3-20 seconds.
    // TODO: we can improve it.
    func getNonceFromServerSynchronous() -> Int64 {
        let start = Date()
        print("Start getNonceFromServerSynchronous")
        let semaphore = DispatchSemaphore(value: 0)
        
        if let address = CurrentAppWalletDataManager.shared.getCurrentAppWallet()?.address {
            EthereumAPIRequest.eth_getTransactionCount(data: address, block: BlockTag.pending, completionHandler: { (data, error) in
                print("Receive callback in getNonceFromServerSynchronous")
                guard error == nil, let data = data else {
                    return
                }
                if data.respond.isHex() {
                    self.nonce = Int64(data.respond.dropFirst(2), radix: 16)!
                } else {
                    self.nonce = Int64(data.respond)!
                }
                print("Current nounce: \(self.nonce)")
                semaphore.signal()
                let end = Date()
                let timeInterval: Double = end.timeIntervalSince(start)
                print("Time to getNonceFromServerSynchronous: \(timeInterval) seconds")
            })
        }
        
        _ = semaphore.wait(timeout: .distantFuture)
        return self.nonce
    }
    
    func getNonceFromServer() {
        let start = Date()
        if let address = CurrentAppWalletDataManager.shared.getCurrentAppWallet()?.address {
            EthereumAPIRequest.eth_getTransactionCount(data: address, block: BlockTag.pending, completionHandler: { (data, error) in
                guard error == nil, let data = data else {
                    return
                }
                if data.respond.isHex() {
                    self.nonce = Int64(data.respond.dropFirst(2), radix: 16)!
                } else {
                    self.nonce = Int64(data.respond)!
                }
                print("Current nounce: \(self.nonce)")
                let end = Date()
                let timeInterval: Double = end.timeIntervalSince(start)
                print("Time to getNonceFromServer: \(timeInterval) seconds")
            })
        }
    }
    
    func sendTransactionToServer(_ signedTransaction: String, completion: @escaping (String?, Error?) -> Void) {
        let start = Date()
        EthereumAPIRequest.eth_sendRawTransaction(data: signedTransaction) { (data, error) in
            guard error == nil && data != nil else {
                completion(nil, error)
                return
            }
            completion(data!.respond, nil)
            let end1 = Date()
            let timeInterval1: Double = end1.timeIntervalSince(start)
            print("Time to sendTransactionToServer: \(timeInterval1) seconds")
        }
    }
    
    func _keystore() {
        let start = Date()
        let wallet = CurrentAppWalletDataManager.shared.getCurrentAppWallet()
        var gethAccount: GethAccount?
    
        // Get Keystore string value
        let keystoreStringValue: String = wallet!.getKeystore()
        print(keystoreStringValue)
        
        // Create key directory
        let fileManager = FileManager.default
        
        let keyDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KeyStoreSendAssetViewController")
        try? fileManager.removeItem(at: keyDirectory)
        try? fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true, attributes: nil)
        print(keyDirectory)
        
        let walletDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WalletSendAssetViewController")
        try? fileManager.removeItem(at: walletDirectory)
        try? fileManager.createDirectory(at: walletDirectory, withIntermediateDirectories: true, attributes: nil)
        print(walletDirectory)
        
        // Save the keystore string value to keyDirectory
        let fileURL = keyDirectory.appendingPathComponent("key.json")
        try! keystoreStringValue.write(to: fileURL, atomically: false, encoding: .utf8)
        
        print(keyDirectory.absoluteString)
        let keydir = keyDirectory.absoluteString.replacingOccurrences(of: "file://", with: "", options: .regularExpression)
        
        let gethKeystore = GethKeyStore.init(keydir, scryptN: GethLightScryptN, scryptP: GethLightScryptP)!
        
        gethAccount = EthAccountCoordinator.default.launch(keystore: gethKeystore, password: wallet!.getPassword())
    
        print("current address: \(gethAccount!.getAddress().getHex())")
        let end = Date()
        let timeInterval: Double = end.timeIntervalSince(start)
        print("Time to _keystore: \(timeInterval) seconds")
    }
    
    // convert weth -> eth
    func _withDraw(amount: GethBigInt, gasPrice: GethBigInt, completion: @escaping (String?, Error?) -> Void) {
        guard CurrentAppWalletDataManager.shared.getCurrentAppWallet() != nil else {
            return
        }
        let transferFunction = EthFunction(name: "withdraw", inputParameters: [amount])
        let data = web3swift.encode(transferFunction)
        let gasLimit: Int64 = getGasLimitByType(type: "withdraw")!
        _transfer(data: data, address: wethAddress!, amount: GethBigInt(0), gasPrice: gasPrice, gasLimit: GethBigInt(gasLimit), completion: completion)
    }
    
    // convert eth -> weth
    func _deposit(amount: GethBigInt, gasPrice: GethBigInt, completion: @escaping (String?, Error?) -> Void) {
        guard CurrentAppWalletDataManager.shared.getCurrentAppWallet() != nil else {
            return
        }
        let transferFunction = EthFunction(name: "deposit", inputParameters: [])
        let data = web3swift.encode(transferFunction)
        let gasLimit: Int64 = getGasLimitByType(type: "deposit")!
        _transfer(data: data, address: wethAddress!, amount: amount, gasPrice: gasPrice, gasLimit: GethBigInt(gasLimit), completion: completion)
    }
    
    // transfer eth
    func _transferETH(amount: GethBigInt, gasPrice: GethBigInt, toAddress: GethAddress, completion: @escaping (String?, Error?) -> Void) {
        guard CurrentAppWalletDataManager.shared.getCurrentAppWallet() != nil else {
            return
        }
        let transferFunction = EthFunction(name: "payable", inputParameters: [toAddress, amount])
        let data = web3swift.encode(transferFunction)
        let gasLimit: Int64 = getGasLimitByType(type: "eth_transfer")!
        _transfer(data: data, address: toAddress, amount: amount, gasPrice: gasPrice, gasLimit: GethBigInt(gasLimit), completion: completion)
    }
    
    // transfer tokens including weth
    func _transferToken(contractAddress: GethAddress, toAddress: GethAddress, tokenAmount: GethBigInt, gasPrice: GethBigInt, completion: @escaping (String?, Error?) -> Void) {
        guard CurrentAppWalletDataManager.shared.getCurrentAppWallet() != nil else {
            return
        }
        // Transfer function
        let transferFunction = EthFunction(name: "transfer", inputParameters: [toAddress, tokenAmount])
        let data = web3swift.encode(transferFunction)
        let gasLimit: Int64 = getGasLimitByType(type: "token_transfer")!
        
        // amount must be 0 for ERC20 tokens.
        _transfer(data: data, address: contractAddress, amount: GethBigInt.init(0), gasPrice: gasPrice, gasLimit: GethBigInt(gasLimit), completion: completion)
    }
    
    func _transfer(data: Data, address: GethAddress, amount: GethBigInt, gasPrice: GethBigInt, gasLimit: GethBigInt, completion: @escaping (String?, Error?) -> Void) {
        _keystore()
        var userInfo: [String: Any] = [:]
        do {
            // Async call. Of course we need to clean the following code.
            // Copy getNonceFromServer
            let start = Date()
            if let publicAddress = CurrentAppWalletDataManager.shared.getCurrentAppWallet()?.address {
                EthereumAPIRequest.eth_getTransactionCount(data: publicAddress, block: BlockTag.pending, completionHandler: { (getTransactionCountData, error) in
                    guard error == nil, let getTransactionCountData = getTransactionCountData else {
                        return
                    }
                    if getTransactionCountData.respond.isHex() {
                        self.nonce = Int64(getTransactionCountData.respond.dropFirst(2), radix: 16)!
                    } else {
                        self.nonce = Int64(getTransactionCountData.respond)!
                    }
                    print("Current nounce: \(self.nonce)")
                    let end1 = Date()
                    let timeInterval1: Double = end1.timeIntervalSince(start)
                    print("Time to getNonceFromServer in _transfer: \(timeInterval1) seconds")
                    
                    // Sign Transaction
                    do {
                        let signedTransaction = web3swift.sign(address: address, encodedFunctionData: data, nonce: self.nonce, amount: amount, gasLimit: gasLimit, gasPrice: gasPrice, password: CurrentAppWalletDataManager.shared.getCurrentAppWallet()!.getPassword())
                        if let signedTransactionData = try signedTransaction?.encodeRLP() {
                            self.sendTransactionToServer("0x" + signedTransactionData.hexString, completion: completion)
                        } else {
                            userInfo["message"] = NSLocalizedString("Failed to sign/encode", comment: "")
                            let error = NSError(domain: "TRANSFER", code: 0, userInfo: userInfo)
                            completion(nil, error)
                        }
                        let end2 = Date()
                        let timeInterval2: Double = end2.timeIntervalSince(end1)
                        print("Time to sign transactinon in _transfer: \(timeInterval2) seconds")
                    } catch {
                        userInfo["message"] = NSLocalizedString("Failed to encode transaction", comment: "")
                        let error = NSError(domain: "TRANSFER", code: 0, userInfo: userInfo)
                        completion(nil, error)
                    }
                })
            }
            /*
            let nonce: Int64 = getNonceFromServerSynchronous()
            let signedTransaction = web3swift.sign(address: address, encodedFunctionData: data, nonce: nonce, amount: amount, gasLimit: gasLimit, gasPrice: gasPrice, password: CurrentAppWalletDataManager.shared.getCurrentAppWallet()!.getPassword())
            if let signedTransactionData = try signedTransaction?.encodeRLP() {
                sendTransactionToServer("0x" + signedTransactionData.hexString, completion: completion)
            } else {
                userInfo["message"] = NSLocalizedString("Failed to sign/encode", comment: "")
                let error = NSError(domain: "TRANSFER", code: 0, userInfo: userInfo)
                completion(nil, error)
            }
            */
        } catch {
            userInfo["message"] = NSLocalizedString("Failed to encode transaction", comment: "")
            let error = NSError(domain: "TRANSFER", code: 0, userInfo: userInfo)
            completion(nil, error)
        }
    }

}
