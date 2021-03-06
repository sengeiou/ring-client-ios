/*
 *  Copyright (C) 2017-2020 Savoir-faire Linux Inc.
 *
 *  Author: Silbino Gonçalves Matado <silbino.gmatado@savoirfairelinux.com>
 *  Author: Quentin Muret <quentin.muret@savoirfairelinux.com>
 *  Author: Kateryna Kostiuk <kateryna.kostiuk@savoirfairelinux.com>
 *  Author: Andreas Traczyk <andreas.traczyk@savoirfairelinux.com>
 *  Author: Raphaël Brulé <raphael.brule@savoirfairelinux.com>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA.
 */

import UIKit
import RxSwift
import Reusable
import SwiftyBeaver
import Photos
import MobileCoreServices

// swiftlint:disable file_length
// swiftlint:disable type_body_length
class ConversationViewController: UIViewController,
                                  UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                                  UIDocumentPickerDelegate, StoryboardBased, ViewModelBased, MessageAccessoryViewDelegate {

    let log = SwiftyBeaver.self

    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var spinnerView: UIView!

    let disposeBag = DisposeBag()

    var viewModel: ConversationViewModel!
    var messageViewModels: [MessageViewModel]?
    var textFieldShouldEndEditing = false
    var bottomOffset: CGFloat = 0
    private let scrollOffsetThreshold: CGFloat = 600
    private let messageGroupingInterval = 10 * 60 // 10 minutes
    var bottomHeight: CGFloat = 0.00
    var isExecutingDeleteMessage: Bool = false

    @IBOutlet weak var currentCallButton: UIButton!
    @IBOutlet weak var currentCallLabel: UILabel!
    @IBOutlet weak var scanButtonLeadingConstraint: NSLayoutConstraint!
    @IBOutlet weak var callButtonHeightConstraint: NSLayoutConstraint!

    var keyboardDismissTapRecognizer: UITapGestureRecognizer!

    private lazy var locationManager: CLLocationManager = { return CLLocationManager() }()

    func setIsComposing(isComposing: Bool) {
        self.viewModel.setIsComposingMsg(isComposing: isComposing)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        messageAccessoryView.delegate = self

        self.configureRingNavigationBar()
        self.setupUI()
        self.setupTableView()
        self.setupBindings()
        NotificationCenter.default.rx
            .notification(UIDevice.orientationDidChangeNotification)
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: {[weak self](_) in
                guard let self = self else {
                    return
                }
                self.setupNavTitle(profileImageData: self.viewModel.profileImageData.value,
                                   displayName: self.viewModel.displayName.value,
                                   username: self.viewModel.userName.value)
                self.tableView.reloadData()
            })
            .disposed(by: self.disposeBag)

        /*
         Register to keyboard notifications to adjust tableView insets when the keybaord appears
         or disappears
         */
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(withNotification:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(withNotification:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)

        keyboardDismissTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
    }

    @objc
    private func applicationWillResignActive() {
        self.viewModel.setIsComposingMsg(isComposing: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: UIBarMetrics.default)
        self.navigationController?.navigationBar.layer.shadowColor = UIColor.jamiNavigationBarShadow.cgColor
    }

    private func importDocument() {
        let documentPicker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .import)
        documentPicker.delegate = self
        documentPicker.modalPresentationStyle = .formSheet
        self.present(documentPicker, animated: true, completion: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let filePath = urls[0].absoluteURL.path
        self.log.debug("Successfully imported \(filePath)")
        let fileName = urls[0].absoluteURL.lastPathComponent
        let fileExtension = urls[0].pathExtension
        if !fileExtension.isMediaExtension() && !fileExtension.isImageExtension() {
            self.viewModel.sendFile(filePath: filePath, displayName: fileName)
            return
        }
        do {
            let data = try Data(contentsOf: urls[0])
            self.viewModel.sendAndSaveFile(displayName: fileName, imageData: data)
        } catch {
            self.viewModel.sendFile(filePath: filePath, displayName: fileName)
        }
    }

    private func showNoPermissionsAlert(title: String) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: "OK", style: .default) { (_: UIAlertAction!) -> Void in }
        alert.addAction(okAction)
        self.present(alert, animated: true, completion: nil)
    }

    func checkPhotoLibraryPermission() {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized:
            self.importImage()
        case .denied, .restricted :
            self.showNoPermissionsAlert(title: L10n.Alerts.noLibraryPermissionsTitle)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { status in
                switch status {
                case .authorized:
                    self.importImage()
                case .denied, .restricted:
                    self.showNoPermissionsAlert(title: L10n.Alerts.noLibraryPermissionsTitle)
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        @unknown default:
            break
        }
    }

    @objc
    func imageTapped() {
        let alert = UIAlertController.init(title: nil,
                                           message: nil,
                                           preferredStyle: .actionSheet)
        let pictureAction = UIAlertAction(title: L10n.Alerts.uploadPhoto, style: UIAlertAction.Style.default) {[weak self] _ in
            self?.checkPhotoLibraryPermission()
        }

        let recordVideoAction = UIAlertAction(title: L10n.Alerts.recordVideoMessage, style: UIAlertAction.Style.default) {[weak self] _ in
            if AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) == AVAuthorizationStatus.authorized {
                if AVCaptureDevice.authorizationStatus(for: AVMediaType.video) == AVAuthorizationStatus.authorized {
                    self?.viewModel.recordVideoFile()
                } else {
                    AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { (granted: Bool) -> Void in
                        if granted == true {
                            self?.viewModel.recordVideoFile()
                        } else {
                            self?.showNoPermissionsAlert(title: L10n.Alerts.noMediaPermissionsTitle)
                        }
                    })
                }
            } else {
                AVCaptureDevice.requestAccess(for: AVMediaType.audio, completionHandler: { (granted: Bool) -> Void in
                    if granted == true {
                        if AVCaptureDevice.authorizationStatus(for: AVMediaType.video) == AVAuthorizationStatus.authorized {
                            self?.viewModel.recordVideoFile()
                        } else {
                            AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { (granted: Bool) -> Void in
                                if granted == true {
                                    self?.viewModel.recordVideoFile()
                                } else {
                                    self?.showNoPermissionsAlert(title: L10n.Alerts.noMediaPermissionsTitle)
                                }
                            })
                        }
                    } else {
                        self?.showNoPermissionsAlert(title: L10n.Alerts.noMediaPermissionsTitle)
                    }
                })
            }
        }

        let recordAudioAction = UIAlertAction(title: L10n.Alerts.recordAudioMessage, style: UIAlertAction.Style.default) { [weak self] _ in
            if AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) == AVAuthorizationStatus.authorized {
                self?.viewModel.recordAudioFile()
            } else {
                AVCaptureDevice.requestAccess(for: AVMediaType.audio, completionHandler: { (granted: Bool) -> Void in
                    if granted == true {
                        self?.viewModel.recordAudioFile()
                    } else {
                        self?.showNoPermissionsAlert(title: L10n.Alerts.noMediaPermissionsTitle)
                    }
                })
            }
        }

        let documentsAction = UIAlertAction(title: L10n.Alerts.uploadFile, style: UIAlertAction.Style.default) { _ in
            self.importDocument()
        }

        let cancelAction = UIAlertAction(title: L10n.Alerts.profileCancelPhoto, style: UIAlertAction.Style.cancel)

        alert.addAction(pictureAction)
        alert.addAction(recordVideoAction)
        alert.addAction(recordAudioAction)
        alert.addAction(documentsAction)
        alert.addAction(locationSharingAction())
        alert.addAction(cancelAction)
        alert.popoverPresentationController?.sourceView = self.view
        alert.popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection()
        alert.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxX, width: 0, height: 0)
        self.present(alert, animated: true, completion: nil)
    }

    func takePicture() {
        if UIImagePickerController.isSourceTypeAvailable(UIImagePickerController.SourceType.camera) {
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            imagePicker.sourceType = UIImagePickerController.SourceType.camera
            imagePicker.cameraDevice = UIImagePickerController.CameraDevice.rear
            imagePicker.modalPresentationStyle = .overFullScreen
            self.present(imagePicker, animated: false, completion: nil)
        }
    }

    func fixImageOrientation(image: UIImage) -> UIImage {
        UIGraphicsBeginImageContext(image.size)
        image.draw(at: .zero)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage ?? image
    }

    func importImage() {
        let imagePicker = UIImagePickerController()
        imagePicker.delegate = self
        imagePicker.allowsEditing = true
        imagePicker.sourceType = UIImagePickerController.SourceType.photoLibrary
        imagePicker.mediaTypes = [kUTTypeImage as String, kUTTypeMovie as String]
        imagePicker.modalPresentationStyle = .overFullScreen
        self.present(imagePicker, animated: true, completion: nil)
    }

    func copyImageToCache(image: UIImage, imagePath: String) {
        guard let imageData = image.pngData() else { return }
        do {
            self.log.debug("copying image to: \(String(describing: imagePath))")
            try imageData.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
        } catch {
            self.log.error("couldn't copy image to cache")
        }
    }

    // swiftlint:disable cyclomatic_complexity
    internal func imagePickerController(_ picker: UIImagePickerController,
                                        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {

        picker.dismiss(animated: true, completion: nil)

        var image: UIImage!

        if picker.sourceType == UIImagePickerController.SourceType.camera {
            // image from camera
            if let img = info[.editedImage] as? UIImage {
                image = img
            } else if let img = info[.originalImage] as? UIImage {
                image = self.fixImageOrientation(image: img)
            }
            // copy image to tmp
            let imageFileName = "IMG.png"
            guard let imageData = image.pngData() else { return }
            self.viewModel.sendAndSaveFile(displayName: imageFileName, imageData: imageData)
        } else if picker.sourceType == UIImagePickerController.SourceType.photoLibrary {
            // image from library
            guard let phAsset = info[UIImagePickerController.InfoKey.phAsset] as? PHAsset else { return }
            var imageFileName = phAsset.value(forKey: "filename") as? String ?? "Unknown"

            // seems that HEIC, HEIF, and JPG files in the iOS photo library start with 0x89 0x50 (png)
            // so funky cold medina
            let pathExtension = (imageFileName as NSString).pathExtension
            if pathExtension.caseInsensitiveCompare("heic") == .orderedSame ||
               pathExtension.caseInsensitiveCompare("heif") == .orderedSame ||
               pathExtension.caseInsensitiveCompare("jpg") == .orderedSame {
                imageFileName = (imageFileName as NSString).deletingPathExtension + ".png"
            }

            guard let localCachePath = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(imageFileName) else {
                return
            }
            self.log.debug("localCachePath: \(String(describing: localCachePath))")

            if phAsset.mediaType == .image {
                if let img = info[.editedImage] as? UIImage {
                    image = img
                } else if let img = info[.originalImage] as? UIImage {
                    image = img
                }
                // copy image to tmp
                copyImageToCache(image: image, imagePath: localCachePath.path)
                self.viewModel.sendFile(filePath: localCachePath.path,
                                        displayName: imageFileName,
                                        localIdentifier: phAsset.localIdentifier)
            } else if phAsset.mediaType == .video {
                PHImageManager.default().requestAVAsset(forVideo: phAsset,
                                                        options: PHVideoRequestOptions(),
                                                        resultHandler: { (asset, _, _) -> Void in
                    guard let asset = asset as? AVURLAsset else {
                        self.log.error("couldn't get asset")
                        return
                    }
                    guard let videoData = NSData(contentsOf: asset.url) else {
                        self.log.error("couldn't get movie data")
                        return
                    }
                    self.log.debug("copying movie to: \(String(describing: localCachePath))")
                    videoData.write(toFile: localCachePath.path, atomically: true)
                    self.viewModel.sendAndSaveFile(displayName: imageFileName,
                                                   imageData: videoData as Data)
                })
            }
        }
    }
    // swiftlint:enable cyclomatic_complexity

    @objc
    func dismissKeyboard() {
        self.becomeFirstResponder()
        view.removeGestureRecognizer(keyboardDismissTapRecognizer)
    }

    @objc
    func keyboardWillShow(withNotification notification: Notification) {
        guard let userInfo: Dictionary = notification.userInfo else {
            return
        }
        guard let keyboardFrame: NSValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }

        let keyboardRectangle = keyboardFrame.cgRectValue
        let keyboardHeight = keyboardRectangle.height

        var heightOffset = CGFloat(0.0)
        if keyboardHeight != self.messageAccessoryView.frame.height {
            if UIDevice.current.hasNotch {
                heightOffset = -35
            }
            self.view.addGestureRecognizer(keyboardDismissTapRecognizer)
        }

        self.tableView.contentInset.bottom = keyboardHeight + heightOffset
        self.tableView.scrollIndicatorInsets.bottom = keyboardHeight + heightOffset
        self.bottomHeight = keyboardHeight + heightOffset

        if keyboardHeight > self.messageAccessoryView.frame.height {
            self.scrollToBottom(animated: false)
        }
        self.updateBottomOffset()
    }

    @objc
    func keyboardWillHide(withNotification notification: Notification) {
        self.tableView.contentInset.bottom = self.messageAccessoryView.frame.height
        self.tableView.scrollIndicatorInsets.bottom = self.messageAccessoryView.frame.height
        self.updateBottomOffset()
    }

    func setupNavTitle(profileImageData: Data?, displayName: String? = nil, username: String?) {
        let isPortrait = UIScreen.main.bounds.size.width < UIScreen.main.bounds.size.height
        let imageSize = isPortrait ? CGFloat(36.0) : CGFloat(32.0)
        let imageOffsetY = CGFloat(5.0)
        let infoPadding = CGFloat(8.0)
        let maxNameLength = CGFloat(128.0)
        var userNameYOffset = CGFloat(9.0)
        var nameSize = CGFloat(18.0)
        let navbarFrame = self.navigationController?.navigationBar.frame
        let totalHeight = ((navbarFrame?.size.height ?? 0) + (navbarFrame?.origin.y ?? 0)) / 2

        // Replace "< Home" with a back arrow while we are crunching everything to the left side of the bar for now.
        self.navigationController?.navigationBar.backIndicatorImage = UIImage(named: "back_button")
        self.navigationController?.navigationBar.backIndicatorTransitionMaskImage = UIImage(named: "back_button")
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: UIBarButtonItem.Style.plain, target: nil, action: nil)

        let titleView: UIView = UIView.init(frame: CGRect(x: 0, y: 0, width: view.frame.width - 32, height: totalHeight))

        let profileImageView = UIImageView(frame: CGRect(x: 0, y: imageOffsetY, width: imageSize, height: imageSize))
        profileImageView.frame = CGRect.init(x: 0, y: 0, width: imageSize, height: imageSize)
        profileImageView.center = CGPoint.init(x: imageSize / 2, y: titleView.center.y)

        if let profileName = displayName, !profileName.isEmpty {
            profileImageView.addSubview(AvatarView(profileImageData: profileImageData, username: profileName, size: 30))
            titleView.addSubview(profileImageView)
        } else if let bestId = username {
            profileImageView.addSubview(AvatarView(profileImageData: profileImageData, username: bestId, size: 30))
            titleView.addSubview(profileImageView)
        }

        var dnlabelYOffset: CGFloat = 0
        if !isPortrait {
            userNameYOffset = 0
        } else if UIDevice.current.hasNotch {
            if displayName == nil || displayName == "" {
                userNameYOffset = 7
            } else {
                dnlabelYOffset = 2
                userNameYOffset = 18
            }
        } else {
            if displayName == nil || displayName == "" {
                userNameYOffset = 1
            } else {
                dnlabelYOffset = -4
                userNameYOffset = 10
            }
        }

        if let name = displayName, !name.isEmpty {
            let dnlabel: UILabel = UILabel.init(frame: CGRect.init(x: imageSize + infoPadding, y: dnlabelYOffset, width: maxNameLength, height: 20))
            dnlabel.text = name
            dnlabel.font = UIFont.systemFont(ofSize: nameSize)
            dnlabel.textColor = UIColor.jamiMain
            dnlabel.textAlignment = .left
            titleView.addSubview(dnlabel)
            nameSize = 14.0
        }

        if isPortrait || displayName == nil || displayName == "" {
            let frame = CGRect.init(x: imageSize + infoPadding,
                                    y: userNameYOffset,
                                    width: maxNameLength,
                                    height: 24)

            let unlabel: UILabel = UILabel.init(frame: frame)
            unlabel.text = username
            unlabel.font = UIFont.systemFont(ofSize: nameSize)
            unlabel.textColor = UIColor.jamiMain
            unlabel.textAlignment = .left
            titleView.addSubview(unlabel)
        }
        let tapGesture = UITapGestureRecognizer()
        titleView.addGestureRecognizer(tapGesture)
        tapGesture.rx.event
            .throttle(RxTimeInterval(2), scheduler: MainScheduler.instance)
            .bind(onNext: { [weak self] _ in
                self?.contactTapped()
            })
            .disposed(by: disposeBag)
        titleView.backgroundColor = UIColor.clear

        self.navigationItem.titleView = titleView
    }

    func contactTapped() {
        self.viewModel.showContactInfo()
    }

   // swiftlint:disable function_body_length
    func setupUI() {
        self.messageAccessoryView.sendButton.contentVerticalAlignment = .fill
        self.messageAccessoryView.sendButton.contentHorizontalAlignment = .fill
        spinnerView.backgroundColor = UIColor.jamiMsgBackground
        self.tableView.backgroundColor = UIColor.jamiMsgBackground
        self.view.backgroundColor = UIColor.jamiMsgTextFieldBackground

        if self.viewModel.isAccountSip {
            self.messageAccessoryView.frame.size.height = 0
            self.messageAccessoryView.isHidden = true
        }

        self.messageAccessoryView.shareButton.rx.tap
            .subscribe(onNext: { [weak self] in
                self?.imageTapped()
            })
            .disposed(by: self.disposeBag)

        self.messageAccessoryView.cameraButton.rx.tap
            .subscribe(onNext: { [weak self] in
                self?.takePicture()
            })
            .disposed(by: self.disposeBag)

        self.setupNavTitle(profileImageData: self.viewModel.profileImageData.value,
                           displayName: self.viewModel.displayName.value,
                           username: self.viewModel.userName.value)

        Observable<(Data?, String?, String)>.combineLatest(self.viewModel.profileImageData.asObservable(),
                                                           self.viewModel.displayName.asObservable(),
                                                           self.viewModel.userName.asObservable()) { profileImage, displayName, username in
                                                            return (profileImage, displayName, username)
        }
            .observeOn(MainScheduler.instance)
            .subscribe({ [weak self] profileData -> Void in
                self?.setupNavTitle(profileImageData: profileData.element?.0,
                                    displayName: profileData.element?.1,
                                    username: profileData.element?.2)
                return
            })
            .disposed(by: self.disposeBag)

        self.tableView.contentInset.bottom = messageAccessoryView.frame.size.height
        self.tableView.scrollIndicatorInsets.bottom = messageAccessoryView.frame.size.height

        //set navigation buttons - call and send contact request
        let inviteItem = UIBarButtonItem()
        inviteItem.image = UIImage(named: "add_person")
        inviteItem.rx.tap.throttle(0.5, scheduler: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.inviteItemTapped()
            })
            .disposed(by: self.disposeBag)

        self.viewModel.inviteButtonIsAvailable.asObservable()
            .bind(to: inviteItem.rx.isEnabled)
            .disposed(by: disposeBag)

        // call button
        let audioCallItem = UIBarButtonItem()
        audioCallItem.image = UIImage(asset: Asset.callButton)
        audioCallItem.rx.tap.throttle(0.5, scheduler: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.placeAudioOnlyCall()
            })
            .disposed(by: self.disposeBag)

        let videoCallItem = UIBarButtonItem()
        videoCallItem.image = UIImage(asset: Asset.videoRunning)
        videoCallItem.rx.tap.throttle(0.5, scheduler: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.placeCall()
            })
            .disposed(by: self.disposeBag)

        // Items are from right to left
        if self.viewModel.isAccountSip {
            self.navigationItem.rightBarButtonItem = audioCallItem
        } else {
            self.navigationItem.rightBarButtonItems = [videoCallItem, audioCallItem, inviteItem]
            self.viewModel.inviteButtonIsAvailable
                .asObservable()
                .map({ inviteButton in
                    var buttons = [UIBarButtonItem]()
                    buttons.append(videoCallItem)
                    buttons.append(audioCallItem)
                    if inviteButton {
                        buttons.append(inviteItem)
                    }
                    return buttons
                })
                .observeOn(MainScheduler.instance)
                .subscribe(onNext: { [weak self] buttons in
                    self?.navigationItem.rightBarButtonItems = buttons
                })
                .disposed(by: self.disposeBag)
        }
        self.viewModel.showCallButton
            .observeOn(MainScheduler.instance)
            .startWith(self.viewModel.haveCurrentCall())
            .subscribe(onNext: { [weak self] show in
                if show {
                    DispatchQueue.main.async {
                        if self?.viewModel.currentCallId.value.isEmpty ?? true {
                            return
                        }
                        self?.currentCallButton.isHidden = false
                        self?.currentCallLabel.isHidden = false
                        self?.callButtonHeightConstraint.constant = 60
                    }
                    return
                }
                self?.currentCallButton.isHidden = true
                self?.currentCallLabel.isHidden = true
                self?.callButtonHeightConstraint.constant = 0
            })
            .disposed(by: disposeBag)
        currentCallButton.rx.tap
            .throttle(0.5, scheduler: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.viewModel.openCall()
            })
            .disposed(by: self.disposeBag)
    }

    func inviteItemTapped() {
       self.viewModel?.sendContactRequest()
    }

    func placeCall() {
        self.textFieldShouldEndEditing = true
        self.messageAccessoryView.messageTextView.resignFirstResponder()
        self.resignFirstResponder()
        self.viewModel.startCall()
    }

    func placeAudioOnlyCall() {
        self.textFieldShouldEndEditing = true
        self.messageAccessoryView.messageTextView.resignFirstResponder()
        self.resignFirstResponder()
        self.viewModel.startAudioCall()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.scrollToBottom(animated: false)
        self.textFieldShouldEndEditing = false
        self.messagesLoadingFinished()
        self.viewModel.setMessagesAsRead()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.viewModel.setIsComposingMsg(isComposing: false)
        self.textFieldShouldEndEditing = true
        self.viewModel.setMessagesAsRead()
    }

    func setupTableView() {
        self.tableView.dataSource = self

        self.tableView.estimatedRowHeight = UITableView.automaticDimension
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.separatorStyle = .none

        //Register cell
        self.tableView.register(cellType: MessageCellSent.self)
        self.tableView.register(cellType: MessageCellReceived.self)
        self.tableView.register(cellType: MessageCellDataTransferSent.self)
        self.tableView.register(cellType: MessageCellDataTransferReceived.self)
        self.tableView.register(cellType: MessageCellGenerated.self)
        self.tableView.register(cellType: MessageCellLocationSharingSent.self)
        self.tableView.register(cellType: MessageCellLocationSharingReceived.self)

        //Bind the TableView to the ViewModel
        self.viewModel.messages.asObservable()
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] (messageViewModels) in
                self?.messageViewModels = messageViewModels
                self?.computeSequencing()
                self?.tableView.reloadData()
            })
            .disposed(by: self.disposeBag)

        //Scroll to bottom when reloaded
        self.tableView.rx.methodInvoked(#selector(UITableView.reloadData))
            .subscribe(onNext: { [weak self] _ in
                self?.scrollToBottomIfNeed()
                self?.updateBottomOffset()
            })
            .disposed(by: disposeBag)
    }

    private func updateBottomOffset() {
        self.bottomOffset = self.tableView.contentSize.height
            - ( self.tableView.frame.size.height
                - self.tableView.contentInset.top
                - self.tableView.contentInset.bottom )
    }

    private func messagesLoadingFinished() {
        self.spinnerView.isHidden = true
    }

    private func scrollToBottomIfNeed() {
        if (self.isBottomContentOffset || !self.tableView.isScrollEnabled) && !self.isExecutingDeleteMessage {
            self.scrollToBottom(animated: false)
        }
        if self.isExecutingDeleteMessage {
            self.isExecutingDeleteMessage = false
        }
    }

    private func scrollToBottom(animated: Bool) {
        let numberOfRows = self.tableView.numberOfRows(inSection: 0)
        if  numberOfRows > 0 {
            let last = IndexPath(row: numberOfRows - 1, section: 0)
            self.tableView.isScrollEnabled = true
            self.tableView.scrollToRow(at: last, at: .bottom, animated: animated)
        }
    }

    private var isBottomContentOffset: Bool {
        self.updateBottomOffset()
        let offset = abs((self.tableView.contentOffset.y + self.tableView.contentInset.top) - bottomOffset)
        return offset <= scrollOffsetThreshold
    }

    override var inputAccessoryView: UIView {
        return self.messageAccessoryView
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    lazy var messageAccessoryView: MessageAccessoryView = {
        return MessageAccessoryView.loadFromNib()
    }()

    func setupBindings() {
        self.messageAccessoryView.sendButton.rx.tap
            .subscribe(onNext: { [weak self] _ in
                guard let payload = self?.messageAccessoryView.messageTextView.text, !payload.isEmpty else {
                    return
                }
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self?.messageAccessoryView.messageTextView.text = ""
                    return
                }
                self?.viewModel.setIsComposingMsg(isComposing: false)
                self?.viewModel.sendMessage(withContent: trimmed)
                self?.messageAccessoryView.messageTextView.text = ""
                self?.messageAccessoryView.setEmojiButtonVisibility(hide: false)
            })
            .disposed(by: self.disposeBag)

        self.messageAccessoryView.emojisButton.rx.tap
            .subscribe(onNext: { [weak self] _ in
                self?.viewModel.sendMessage(withContent: "👍")
            })
            .disposed(by: self.disposeBag)

        self.messageAccessoryView.messageTextViewHeight.asObservable()
            .subscribe(onNext: { [weak self] height in
                self?.tableView.contentInset.bottom = (self?.bottomHeight ?? 0) + height - 35
                self?.tableView.scrollIndicatorInsets.bottom = (self?.bottomHeight ?? 0) + height - 35
                self?.scrollToBottom(animated: true)
                self?.updateBottomOffset()
            })
            .disposed(by: self.disposeBag)

        self.messageAccessoryView.messageTextViewContent.asObservable()
            .subscribe(onNext: { [weak self] _ in
                self?.messageAccessoryView.editingChanges()
            })
            .disposed(by: self.disposeBag)
    }

    // Avoid the keyboard to be hidden when the Send button is touched
    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        return textFieldShouldEndEditing
    }

    // MARK: - message formatting
    private func computeSequencing() {
        var lastMessageTime: Date?
        for (index, messageViewModel) in self.messageViewModels!.enumerated() {
            // time labels
            let currentMessageTime = messageViewModel.receivedDate
            if index == 0 || messageViewModel.bubblePosition() == .generated || messageViewModel.isTransfer {
                // always show first message's time
                messageViewModel.shouldShowTimeString = true
            } else {
                // only show time for new messages if beyond an arbitrary time frame from the previously shown time
                let timeDifference = currentMessageTime.timeIntervalSinceReferenceDate - lastMessageTime!.timeIntervalSinceReferenceDate
                if Int(timeDifference) < messageGroupingInterval || messageViewModel.isComposingIndicator {
                    messageViewModel.shouldShowTimeString = false
                } else {
                    messageViewModel.shouldShowTimeString = true
                }
            }
            lastMessageTime = currentMessageTime
            // sequencing
            messageViewModel.sequencing = getMessageSequencing(forIndex: index)
        }
    }

    private func getMessageSequencing(forIndex index: Int) -> MessageSequencing {
        if let models = self.messageViewModels {
            let messageItem = models[index]
            let msgOwner = messageItem.bubblePosition()
            if models.count == 1 || index == 0 {
                if models.count == index + 1 {
                    return MessageSequencing.singleMessage
                }
                let nextMessageItem = index + 1 <= models.count
                    ? models[index + 1] : nil
                if nextMessageItem != nil {
                    return msgOwner != nextMessageItem?.bubblePosition()
                        ? MessageSequencing.singleMessage : MessageSequencing.firstOfSequence
                }
            } else if models.count == index + 1 {
                let lastMessageItem = index - 1 >= 0 && index - 1 < models.count
                    ? models[index - 1] : nil
                if lastMessageItem != nil {
                    return msgOwner != lastMessageItem?.bubblePosition()
                        ? MessageSequencing.singleMessage : MessageSequencing.lastOfSequence
                }
            }
            let lastMessageItem = index - 1 >= 0 && index - 1 < models.count
                ? models[index - 1] : nil
            let nextMessageItem = index + 1 <= models.count
                ? models[index + 1] : nil
            var sequencing = MessageSequencing.singleMessage
            if (lastMessageItem != nil) && (nextMessageItem != nil) {
                if msgOwner != lastMessageItem?.bubblePosition() && msgOwner == nextMessageItem?.bubblePosition() {
                    sequencing = MessageSequencing.firstOfSequence
                } else if msgOwner != nextMessageItem?.bubblePosition() && msgOwner == lastMessageItem?.bubblePosition() {
                    sequencing = MessageSequencing.lastOfSequence
                } else if msgOwner == nextMessageItem?.bubblePosition() && msgOwner == lastMessageItem?.bubblePosition() {
                    sequencing = MessageSequencing.middleOfSequence
                }
            }
            return sequencing
        }
        return MessageSequencing.unknown
    }

    // swiftlint:disable cyclomatic_complexity
    func changeTransferStatus(_ cell: MessageCell,
                              _ indexPath: IndexPath?,
                              _ status: DataTransferStatus,
                              _ item: MessageViewModel,
                              _ conversationViewModel: ConversationViewModel) {
        switch status {
        case .created:
            if item.bubblePosition() == .sent {
                cell.statusLabel.isHidden = false
                cell.statusLabel.text = L10n.DataTransfer.readableStatusCreated
                cell.statusLabel.textColor = UIColor.darkGray
                cell.progressBar.isHidden = true
                cell.cancelButton.isHidden = false
                cell.cancelButton.setTitle(L10n.DataTransfer.readableStatusCancel, for: .normal)
                cell.buttonsHeightConstraint?.constant = 24.0
            }
        case .error:
            // show status
            cell.statusLabel.isHidden = false
            cell.statusLabel.text = L10n.DataTransfer.readableStatusError
            cell.statusLabel.textColor = UIColor.jamiFailure
            // hide everything and shrink cell
            cell.progressBar.isHidden = true
            cell.acceptButton?.isHidden = true
            cell.cancelButton.isHidden = true
            cell.buttonsHeightConstraint?.constant = 0.0
        case .awaiting:
            cell.progressBar.isHidden = true
            cell.cancelButton.isHidden = false
            cell.buttonsHeightConstraint?.constant = 24.0
            if item.bubblePosition() == .sent {
                // status
                cell.statusLabel.isHidden = false
                cell.statusLabel.text = L10n.DataTransfer.readableStatusAwaiting
                cell.statusLabel.textColor = UIColor.jamiSuccess
                cell.cancelButton.setTitle(L10n.DataTransfer.readableStatusCancel, for: .normal)
            } else if item.bubblePosition() == .received {
                // hide status
                cell.statusLabel.isHidden = true
                cell.acceptButton?.isHidden = false
                cell.cancelButton.setTitle(L10n.DataTransfer.readableStatusRefuse, for: .normal)
            }
        case .ongoing:
            // status
            cell.statusLabel.isHidden = false
            cell.statusLabel.text = L10n.DataTransfer.readableStatusOngoing
            cell.statusLabel.textColor = UIColor.darkGray
            // start update progress timer process bar here
            guard let transferId = item.daemonId else { return }
            let progress = viewModel.getTransferProgress(transferId: transferId) ?? 0.0
            cell.progressBar.progress = progress
            cell.progressBar.isHidden = false
            cell.startProgressMonitor(item, viewModel)
            // hide accept button only
            cell.acceptButton?.isHidden = true
            cell.cancelButton.isHidden = false
            cell.cancelButton.setTitle(L10n.DataTransfer.readableStatusCancel, for: .normal)
            cell.buttonsHeightConstraint?.constant = 24.0
        case .canceled:
            // status
            cell.statusLabel.isHidden = false
            cell.statusLabel.text = L10n.DataTransfer.readableStatusCanceled
            cell.statusLabel.textColor = UIColor.jamiWarning
            // hide everything and shrink cell
            cell.progressBar.isHidden = true
            cell.acceptButton?.isHidden = true
            cell.cancelButton.isHidden = true
            cell.buttonsHeightConstraint?.constant = 0.0
        case .success:
            // status
            cell.statusLabel.isHidden = false
            cell.statusLabel.text = L10n.DataTransfer.readableStatusSuccess
            cell.statusLabel.textColor = UIColor.jamiSuccess
            // hide everything and shrink cell
            cell.progressBar.isHidden = true
            cell.acceptButton?.isHidden = true
            cell.cancelButton.isHidden = true
            cell.buttonsHeightConstraint?.constant = 0.0
        default: break
        }
    }

    func addShareAction(cell: MessageCell, item: MessageViewModel) {
        let doubleTap = UITapGestureRecognizer()
        doubleTap.numberOfTapsRequired = 2
        cell.isUserInteractionEnabled = true
        cell.addGestureRecognizer(doubleTap)
        doubleTap.rx.event
            .bind(onNext: { [weak self] _ in
                self?.showShareMenu(transfer: item)
            })
            .disposed(by: cell.disposeBag)
    }

    func showShareMenu(transfer: MessageViewModel) {
        guard let file = transfer.transferedFile(conversationID: self.viewModel.conversation.value.conversationId) else { return }
        let itemToShare = [file]
        let activityViewController = UIActivityViewController(activityItems: itemToShare, applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceView = self.view
        activityViewController.popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection()
        activityViewController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxX, width: 0, height: 0)
        activityViewController.excludedActivityTypes = [UIActivity.ActivityType.airDrop]
        self.present(activityViewController, animated: true, completion: nil)
    }
}

// MARK: TableDataSource
extension ConversationViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.messageViewModels?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let item = self.messageViewModels?[indexPath.row] {

            if item.message.incoming &&
                item.message.status != .displayed &&
                !item.message.isTransfer {
                self.viewModel.setMessageAsRead(daemonId: item.message.daemonId,
                                                messageId: item.message.messageId)
            }

            let cellType = { (bubblePosition: BubblePosition, isTransfer: Bool, isLocationSharing: Bool) -> MessageCell.Type in
                switch bubblePosition {
                case .received:
                    if isLocationSharing {
                        return MessageCellLocationSharingReceived.self
                    } else if isTransfer {
                        return MessageCellDataTransferReceived.self
                    } else {
                        return MessageCellReceived.self
                    }
                case .sent:
                    if isLocationSharing {
                        return MessageCellLocationSharingSent.self
                    } else if isTransfer {
                        return MessageCellDataTransferSent.self
                    } else {
                        return MessageCellSent.self
                    }
                case .generated: return MessageCellGenerated.self
                }
            }(item.bubblePosition(), item.isTransfer, item.isLocationSharingBubble)

            let cell = tableView.dequeueReusableCell(for: indexPath, cellType: cellType)
            cell.configureFromItem(viewModel, self.messageViewModels, cellForRowAt: indexPath)

            self.transferCellSetup(item, cell, tableView, indexPath)
            self.locationCellSetup(item, cell)
            self.deleteCellSetup(cell)
            self.tapToShowTimeCellSetup(cell)

            return cell
        }
        return tableView.dequeueReusableCell(for: indexPath, cellType: MessageCellSent.self)
    }

    private func deleteCellSetup(_ cell: MessageCell) {
        cell.deleteMessage
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self, weak cell] (shouldDelete) in
                guard shouldDelete, let self = self, let cell = cell, let messageId = cell.messageId else { return }

                if cell as? MessageCellLocationSharing != nil {
                    self.tableView.isScrollEnabled = true
                    if cell as? MessageCellLocationSharingSent != nil {
                        self.viewModel.stopSendingLocation()
                    }
                }
                self.isExecutingDeleteMessage = true
                self.viewModel.deleteMessage(messageId: messageId)
            })
            .disposed(by: cell.disposeBag)
    }

    private func tapToShowTimeCellSetup(_ cell: MessageCell) {
        cell.tappedToShowTime
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self, weak cell] (tappedToShowTime) in
                guard tappedToShowTime, let self = self, let cell = cell else { return }

                let hide = !(cell.timeLabel!.isHidden)
                if hide {
                    cell.toggleCellTimeLabelVisibility()
                }

                self.tableView.performBatchUpdates({
                    self.tableView.updateConstraintsIfNeeded()
                }, completion: { _ in if !hide { cell.toggleCellTimeLabelVisibility() } })
            })
            .disposed(by: cell.disposeBag)
    }

    private func locationCellSetup(_ item: MessageViewModel, _ cell: MessageCell) {
        guard item.isLocationSharingBubble, let cell = cell as? MessageCellLocationSharing else { return }

        cell.locationTapped
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self, weak cell] (locationTapped) in
                guard locationTapped.0, let self = self, let cell = cell else { return }

                let expanding = locationTapped.1

                if let index = self.tableView.indexPath(for: cell) {
                    cell.expandHeight(expanding,
                                      self.tableView.frame.height - self.tableView.contentInset.top - self.tableView.contentInset.bottom)
                    self.tableView.performBatchUpdates({
                        self.tableView.updateConstraintsIfNeeded()
                        UIView.animate(withDuration: 0.4) {
                            cell.updateWidth(expanding)
                            cell.layoutIfNeeded()
                        }
                    }, completion: { [weak cell] _ in cell?.onAnimationCompletion() })

                    if expanding {
                        self.tableView.scrollToRow(at: index, at: UITableView.ScrollPosition.top, animated: true)
                    }
                    self.tableView.isScrollEnabled = !expanding

                    cell.locationTapped.accept((false, expanding))
                } else {
                    self.log.warning("[ConversationViewController] locationCellSetup, something went weird, let's retry")
                    self.tableView.isScrollEnabled = true
                    cell.locationTapped.accept((true, expanding)) // retry
                }
            })
            .disposed(by: cell.disposeBag)
    }

    // swiftlint:disable cyclomatic_complexity
    private func transferCellSetup(_ item: MessageViewModel, _ cell: MessageCell, _ tableView: UITableView, _ indexPath: IndexPath) {
        if item.isTransfer {
            cell.acceptButton?.setTitle(L10n.DataTransfer.readableStatusAccept, for: .normal)
            item.lastTransferStatus = .unknown
            changeTransferStatus(cell, nil, item.message.transferStatus, item, viewModel)
            item.transferStatus.asObservable()
                .observeOn(MainScheduler.instance)
                .filter {
                    return $0 != DataTransferStatus.unknown && $0 != item.lastTransferStatus && $0 != item.initialTransferStatus
                }
                .subscribe(onNext: { [weak self, weak tableView, weak cell] status in
                    guard let cell = cell else { return }
                    guard let currentIndexPath = tableView?.indexPath(for: cell) else { return }
                    guard let transferId = item.daemonId else { return }
                    guard let model = self?.viewModel else { return }
                    self?.log.info("Transfer status change from: \(item.lastTransferStatus.description) to: \(status.description) for transferId: \(transferId) cell row: \(currentIndexPath.row)")
                    if item.bubblePosition() == .sent && item.shouldDisplayTransferedImage {
                        cell.displayTransferedImage(message: item, conversationID: model.conversation.value.conversationId, accountId: model.conversation.value.accountId)
                    } else {
                        self?.changeTransferStatus(cell, currentIndexPath, status, item, model)
                        cell.stopProgressMonitor()
                    }
                    item.lastTransferStatus = status
                    item.initialTransferStatus = status
                    tableView?.reloadData()
                })
                .disposed(by: cell.disposeBag)

            cell.cancelButton.rx.tap
                .subscribe(onNext: { [weak self, weak tableView, weak cell] _ in
                    guard let cell = cell else { return }
                    guard let transferId = item.daemonId else { return }
                    self?.log.info("canceling transferId \(transferId)")
                    _ = self?.viewModel.cancelTransfer(transferId: transferId)
                    item.initialTransferStatus = .canceled
                    item.message.transferStatus = .canceled
                    cell.stopProgressMonitor()
                    tableView?.reloadData()
                })
                .disposed(by: cell.disposeBag)
            cell.openPlayer
                .subscribe(onNext: { [weak self, weak item] open in
                    guard let self = self,
                        open,
                        let player = item?.getPlayer(conversationViewModel: self.viewModel) else { return }
                    self.inputAccessoryView.isHidden = true
                    self.viewModel.openFullScreenPlayer(parentView: self, viewModel: player)
                })
            .disposed(by: cell.disposeBag)
            cell.playerHeight
                .asObservable()
                .share()
                .observeOn(MainScheduler.instance)
                .subscribe(onNext: {[weak tableView] height in
                    if height > 0 {
                        UIView.performWithoutAnimation {
                            guard let sectionNumber = tableView?.numberOfSections,
                                let rowNumber = tableView?.numberOfRows(inSection: indexPath.section) else { return }
                            if indexPath.section < sectionNumber && indexPath.section >= 0 {
                                if indexPath.row < rowNumber &&
                                    indexPath.row >= 0 &&
                                    indexPath.row != tableView?.numberOfRows(inSection: indexPath.section) {
                                    tableView?
                                        .reloadItemsAtIndexPaths([indexPath],
                                                                 animationStyle: .top)
                                }
                            }
                        }
                    }
                })
                .disposed(by: cell.disposeBag)

            if item.bubblePosition() == .received {
                cell.acceptButton?.rx.tap
                    .subscribe(onNext: { [weak self, weak tableView, weak cell] _ in
                        guard let cell = cell else { return }
                        guard let transferId = item.daemonId else { return }
                        self?.log.info("accepting transferId \(transferId)")
                        if self?.viewModel.acceptTransfer(transferId: transferId, interactionID: item.messageId, messageContent: &item.message.content) != .success {
                            _ = self?.viewModel.cancelTransfer(transferId: transferId)
                            item.initialTransferStatus = .canceled
                            item.message.transferStatus = .canceled
                            cell.stopProgressMonitor()
                            tableView?.reloadData()
                        }
                    })
                    .disposed(by: cell.disposeBag)
            }
            if item.message.transferStatus == .success {
                self.addShareAction(cell: cell, item: item)
            }
        }
    }
}

// MARK: Location sharing
extension ConversationViewController {
    private func locationSharingAction() -> UIAlertAction {
        return UIAlertAction(title: L10n.Alerts.locationSharing, style: .default) { [weak self] _ in
            guard let self = self else { return }

            if self.canShareLocation() && self.isNotAlreadySharingWithThisContact() {
                self.askLocationSharingDuration()
            }
        }
    }

    private func askLocationSharingDuration() {
        let alert = UIAlertController.init(title: L10n.Alerts.locationSharingDurationTitle,
                                           message: nil,
                                           preferredStyle: .alert)

        alert.addAction(.init(title: L10n.Alerts.locationSharingDuration10min, style: .default, handler: { [weak self] _ in
            self?.viewModel.startSendingLocation(duration: 10 * 60)
        }))
        alert.addAction(.init(title: L10n.Alerts.locationSharingDuration1hour, style: .default, handler: { [weak self] _ in
            self?.viewModel.startSendingLocation(duration: 60 * 60)
        }))
        alert.addAction(.init(title: L10n.Alerts.profileCancelPhoto, style: UIAlertAction.Style.cancel))

        self.present(alert, animated: true, completion: nil)
    }

    private func isNotAlreadySharingWithThisContact() -> Bool {
        if self.viewModel.isAlreadySharingLocation() {
            let alert = UIAlertController.init(title: L10n.Alerts.alreadylocationSharing,
                                               message: nil,
                                               preferredStyle: .alert)
            alert.addAction(.init(title: L10n.Global.ok, style: UIAlertAction.Style.cancel))
            self.present(alert, animated: true, completion: nil)

            return false
        }
        return true
    }

    private func canShareLocation() -> Bool {
        if CLLocationManager.locationServicesEnabled() {
            return checkLocationAuthorization()
        } else {
            self.showGoToSettingsAlert(title: L10n.Alerts.locationServiceIsDisabled)
            return false
        }
    }

    private func showGoToSettingsAlert(title: String) {
        let alertController = UIAlertController(title: title, message: nil, preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: L10n.Actions.goToSettings, style: .default, handler: { (_) in
            if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, completionHandler: nil)
            }
        }))

        alertController.addAction(UIAlertAction(title: L10n.Actions.cancelAction, style: .cancel, handler: nil))

        self.present(alertController, animated: true, completion: nil)
    }

    private func checkLocationAuthorization() -> Bool {
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied: self.showGoToSettingsAlert(title: L10n.Alerts.noLocationPermissionsTitle)
        case .authorizedAlways, .authorizedWhenInUse: return true
        @unknown default: break
        }

        return false
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
