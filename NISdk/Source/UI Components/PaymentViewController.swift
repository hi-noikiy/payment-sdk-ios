//
//  PaymentViewController.swift
//  NISdk
//
//  Created by Johnny Peter on 19/08/19.
//  Copyright © 2019 Network International. All rights reserved.
//

import Foundation
import PassKit

typealias MakePaymentCallback = (PaymentRequest) -> Void

class PaymentViewController: UIViewController {
    private var state: State?
    private weak var shownViewController: UIViewController?
    
    private let transactionService = TransactionServiceAdapter()
    private weak var cardPaymentDelegate: CardPaymentDelegate?
    private let order: OrderResponse
    private var paymentToken: String?
    private let paymentMedium: PaymentMedium
    private var applePayController: ApplePayController?
    private var applePayDelegate: ApplePayDelegate?
    var applePayRequest: PKPaymentRequest?
    
    init(order: OrderResponse, cardPaymentDelegate: CardPaymentDelegate,
         applePayDelegate: ApplePayDelegate?, paymentMedium: PaymentMedium) {
        self.order = order
        self.cardPaymentDelegate = cardPaymentDelegate
        self.paymentMedium = paymentMedium
        if let applePayDelegate = applePayDelegate {
            self.applePayDelegate = applePayDelegate
        }
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // 1. Perform authorization by aquiring a payment token
        self.authorizePayment()
    }
    
    private func authorizePayment() {
        cardPaymentDelegate?.authorizationDidBegin?()
        self.transition(to: .authorizing)
        if let authCode = order.getAuthCode(),
            let paymentLink = order.orderLinks?.paymentAuthorizationLink {
            transactionService.authorizePayment(for: authCode, using: paymentLink, on: {
                [weak self] paymentToken in
                if let paymentToken = paymentToken {
                    // Callback hell...
                    self?.paymentToken = paymentToken
                    // 2. Show card payment screen after authorization (payment token is received)
                     DispatchQueue.main.async { // Use the main thread to update any UI
                        self?.cardPaymentDelegate?.authorizationDidComplete?(with: .AuthSuccess)
                        self?.cardPaymentDelegate?.paymentDidBegin?()
                        self?.initiatePaymentForm()
                    }
                } else {
                    self?.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: .AuthFailed)
                }
            })
        } else {
            // Close payment view controller if authCode or payment link is broken
           self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: .AuthFailed)
        }
    }
    
    private func initiatePaymentForm() {
        switch paymentMedium {
        case .Card:
            let cardPaymentViewController = CardPaymentViewController(makePaymentCallback: self.makePayment)
            self.transition(to: .renderCardPaymentForm(cardPaymentViewController))
            break;
        case .ApplePay:
            if let applePayRequest = applePayRequest {
                applePayController = ApplePayController(applePayPaymentRequest: applePayRequest,
                                                        applePayDelegate: self.applePayDelegate!,
                                                        order: order,
                                                        onAuthorizeApplePayCallback: handleApplePayAuthorization)
                if let applePayVC = applePayController?.pkPaymentAuthorizationVC {
                    self.transition(to: .renderApplePaySheet(applePayVC))
                    return
                }
            }
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
            break
        }
    }
    
    lazy private var handleApplePayAuthorization: OnAuthorizeApplePayCallback  = {
        [unowned self] payment, completion in
        self.transactionService.postApplePayResponse(for: self.order,
                                                     with: payment,
                                                     using: self.paymentToken!, on: completion)
    }
    
    lazy private var makePayment = { [unowned self] paymentRequest in
        // 3. Make Payment
        self.transactionService.makePayment(for: self.order, with: paymentRequest, using: self.paymentToken!, on: {
            data, response, error in
            if let data = data {
                do {
                    let paymentResponse: PaymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
                    // 4. Intermediatory checks for payment failure attempts and anything else
                    DispatchQueue.main.async {
                        if(paymentResponse.state == "AUTHORISED") {
                            // 5. Close Screen if payment is done
                            self.finishPaymentAndClosePaymentViewController(with: .PaymentSuccess, and: nil, and: nil)
                        } else if(paymentResponse.state == "AWAIT_3DS") {
                            self.cardPaymentDelegate?.threeDSChallengeDidBegin?()
                            self.initiateThreeDS(with: paymentResponse)
                        } else {
                            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                        }
                    }
                } catch let error {
                    print(error)
                }
            }
        })
    }
    
    private func initiateThreeDS(with paymentRepsonse: PaymentResponse) {
        if let acsUrl = paymentRepsonse.threeDSConfig?.acsUrl,
            let acsPaReq = paymentRepsonse.threeDSConfig?.acsMd,
            let acsMd = paymentRepsonse.threeDSConfig?.acsMd,
            let threeDSTermURL = paymentRepsonse.paymentLinks?.threeDSTermURL {
            let threeDSViewController = ThreeDSViewController(with: acsUrl,
                                                              acsPaReq: acsPaReq,
                                                              acsMd: acsMd,
                                                              threeDSTermURL: threeDSTermURL,
                                                              completion: onThreeDSCompletion)
            self.transition(to: .renderThreeDSChallengeForm(threeDSViewController))
        } else {
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: nil)
        }
    }
    
    lazy private var onThreeDSCompletion: (Bool) -> Void = { [weak self] isthreeDSCompletedSuccessfully in
        if(isthreeDSCompletedSuccessfully) {
            self?.finishPaymentAndClosePaymentViewController(with: .PaymentSuccess, and: .ThreeDSSuccess, and: nil)
            return
        }
        self?.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: nil)
    }
    
    // This is called when payment is done(fail or success) with 3ds(fail or success) or without 3ds
    private func finishPaymentAndClosePaymentViewController(with paymentStatus: PaymentStatus,
                                                            and threeDSStatus: ThreeDSStatus?,
                                                            and authStatus: AuthorizationStatus?) {
        DispatchQueue.main.async { // Use the main thread to update any UI
            if let threeDSStatus = threeDSStatus {
                self.cardPaymentDelegate?.threeDSChallengeDidComplete?(with: threeDSStatus)
            }
            
            if let authStatus = authStatus  {
                self.cardPaymentDelegate?.authorizationDidComplete?(with: authStatus)
            }
            
            self.closePaymentViewController(completion: {
                [weak self] in
                self?.cardPaymentDelegate?.paymentDidComplete(with: paymentStatus)
            })
        }
    }
    
    private func closePaymentViewController(completion: (() -> Void)?) {
        dismiss(animated: true, completion: completion)
    }
}

private extension PaymentViewController {
    enum State {
        case authorizing
        case renderCardPaymentForm(UIViewController)
        case renderThreeDSChallengeForm(UIViewController)
        case renderApplePaySheet(UIViewController)
    }
    
    private func transition(to newState: State) {
        shownViewController?.remove()
        let vc = viewController(for: newState)
        add(vc, inside: view)
        shownViewController = vc
        state = newState
    }
    
    func viewController(for state: State) -> UIViewController {
        switch state {
        case .authorizing:
            return AuthorizationViewController()
            
        case .renderCardPaymentForm(let viewController),
             .renderThreeDSChallengeForm(let viewController),
             .renderApplePaySheet(let viewController):
            return viewController
        }
    }
}
