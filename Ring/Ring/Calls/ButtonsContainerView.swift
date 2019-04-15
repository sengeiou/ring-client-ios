/*
 *  Copyright (C) 2017-2019 Savoir-faire Linux Inc.
 *
 *  Author: Kateryna Kostiuk <kateryna.kostiuk@savoirfairelinux.com>
 *  Author: Quentin Muret <quentin.muret@savoirfairelinux.com>
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
import Reusable
import RxSwift

class ButtonsContainerView: UIView, NibLoadable {

    //Outlets
    @IBOutlet var containerView: UIView!
    @IBOutlet  weak var container: UIView!
    @IBOutlet weak var stackView: UIStackView!
    @IBOutlet weak var backgroundBlurEffect: UIVisualEffectView!
    @IBOutlet  weak var muteAudioButton: UIButton!
    @IBOutlet  weak var muteVideoButton: UIButton!
    @IBOutlet  weak var pauseCallButton: UIButton!
    @IBOutlet  weak var dialpadButton: UIButton!
    @IBOutlet  weak var switchSpeakerButton: UIButton!
    @IBOutlet  weak var cancelButton: UIButton!
    @IBOutlet  weak var spaceButton: UIButton!

    //Constraints
    @IBOutlet weak var cancelButtonWidthConstraint: NSLayoutConstraint!
    @IBOutlet weak var cancelButtonBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var cancelButtonHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var stackViewYConstraint: NSLayoutConstraint!
    @IBOutlet weak var stackViewWidthConstraint: NSLayoutConstraint!
    @IBOutlet weak var containerHeightConstraint: NSLayoutConstraint!

    let disposeBag = DisposeBag()
    var isCallStarted: Bool = false

    var viewModel: ButtonsContainerViewModel? {
        didSet {
            self.viewModel?.observableCallOptions
                .observeOn(MainScheduler.instance)
                .subscribe(onNext: { [weak self] callOptions in
                    switch callOptions {
                    case .none:
                        self?.withoutOptions()
                    case .optionsWithoutSpeakerphone:
                        self?.optionsWithoutSpeaker()
                    case .optionsWithSpeakerphone:
                        self?.optionsWithSpeaker()
                    }
                }).disposed(by: self.disposeBag)
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.commonInit()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.commonInit()
    }

    override open func didMoveToWindow() {
        super.didMoveToWindow()
        self.cancelButton.backgroundColor = UIColor.red
    }

    func commonInit() {
        Bundle.main.loadNibNamed("ButtonsContainerView", owner: self, options: nil)
        addSubview(containerView)
        containerView.frame = self.bounds
    }

    func withoutOptions() {
            self.container.backgroundColor = UIColor.clear
            self.backgroundBlurEffect.isHidden = true
            muteAudioButton.isHidden = true
            muteVideoButton.isHidden = true
            pauseCallButton.isHidden = true
            dialpadButton.isHidden = true
            switchSpeakerButton.isHidden = true
            cancelButton.isHidden = false
    }

    func optionsWithSpeaker() {
        if !self.isCallStarted {
            self.isCallStarted = true
            self.backgroundBlurEffect.isHidden = false
            muteAudioButton.isHidden = false
            if self.viewModel?.isAudioOnly ?? false {
                muteVideoButton.isHidden = true
                spaceButton.isHidden = true
                if self.viewModel?.isSipCall ?? false {
                    dialpadButton.isHidden = false
                }
            } else {
                muteVideoButton.isHidden = false
            }
            pauseCallButton.isHidden = false
            switchSpeakerButton.isEnabled = true
            switchSpeakerButton.isHidden = false
            cancelButton.isHidden = false
        }
    }

    func optionsWithoutSpeaker() {
        if !self.isCallStarted {
            self.isCallStarted = true
            if self.viewModel?.isAudioOnly ?? false {
                muteVideoButton.isHidden = true
                spaceButton.isHidden = true
                if self.viewModel?.isSipCall ?? false {
                    dialpadButton.isHidden = false
                }
            } else {
                muteVideoButton.isHidden = false
            }
            switchSpeakerButton.isEnabled = false
            self.muteAudioButton.isHidden = false
            switchSpeakerButton.isHidden = false
            self.backgroundBlurEffect.isHidden = false
            pauseCallButton.isHidden = false
            cancelButton.isHidden = false
        }
    }
}
