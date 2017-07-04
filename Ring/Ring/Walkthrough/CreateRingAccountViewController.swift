/*
 *  Copyright (C) 2016 Savoir-faire Linux Inc.
 *
 *  Author: Romain Bertozzi <romain.bertozzi@savoirfairelinux.com>
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

import RxCocoa
import RxSwift
import PKHUD

fileprivate enum CreateRingAccountCellType {
    case registerPublicUsername
    case usernameField
    case passwordNotice
    case newPasswordField
    case repeatPasswordField
}

class CreateRingAccountViewController: UITableViewController {

    var mAccountViewModel = CreateRingAccountViewModel(withAccountService: AppDelegate.accountService,
                                                       nameService: AppDelegate.nameService)

    @IBOutlet weak var mCreateAccountButton: RoundedButton!
    @IBOutlet weak var mCreateAccountTitleLabel: UILabel!

    /**
     Cell identifiers
     */

    let mSwitchCellId = "SwitchCellId"
    let mTextFieldCellId = "TextFieldCellId"
    let mTextCellId = "TextCellId"

    var mDisposeBag = DisposeBag()

    override func viewDidLoad() {
        super.viewDidLoad()

        self.registerCells()

        self.bindViews()

        self.setupUI()
    }

    func registerCells() {
        self.tableView.register(UINib.init(nibName: "SwitchCell", bundle: nil),
                                forCellReuseIdentifier: mSwitchCellId)

        self.tableView.register(UINib.init(nibName: "TextFieldCell", bundle: nil),
                                forCellReuseIdentifier: mTextFieldCellId)

        self.tableView.register(UINib.init(nibName: "TextCell", bundle: nil),
                                forCellReuseIdentifier: mTextCellId)

    }

    /**
     Bind all the necessary of this View to its ViewModel.
     That allows to build the binding part of the MVVM pattern.
     */
    fileprivate func bindViews() {

        //Add Account button action
        self.mCreateAccountButton
            .rx
            .tap
            .takeUntil(self.rx.deallocated)
            .subscribe(onNext: {
                self.mAccountViewModel.createAccount()
            })
            .addDisposableTo(self.mDisposeBag)

        //Add Account Registration state
        self.mAccountViewModel.accountCreationState.observeOn(MainScheduler.instance).subscribe(
            onNext: { [unowned self] state in
                switch state {
                case .started:
                    self.setCreateAccountAsLoading()
                case .success:
                    self.setCreateAccountAsIdle()
                    self.showDeviceAddedAlert()
                    self.dismiss(animated: true, completion: nil)
                default:
                    return
                }
            },
            onError: { [unowned self] error in
                if let error = error as? AccountCreationError {
                    self.showErrorAlert(error)
                }
                self.setCreateAccountAsIdle()
        }).addDisposableTo(mDisposeBag)

        //Show or hide user name field
        self.mAccountViewModel.registerUsername.asObservable()
            .subscribe(onNext: { [weak self] showUsernameField in
                self?.toggleRegisterSwitch(showUsernameField)
            }).addDisposableTo(mDisposeBag)

        //Enables create account button
        self.mAccountViewModel.canCreateAccount
            .bind(to: self.mCreateAccountButton.rx.isEnabled)
            .addDisposableTo(mDisposeBag)
    }

    /**
     Customize the views
     */

    fileprivate func setupUI() {
        self.tableView.estimatedRowHeight = 44.0
        self.tableView.rowHeight = UITableViewAutomaticDimension

        self.mCreateAccountTitleLabel.text = NSLocalizedString("CreateAccountFormTitle",
                                                               tableName: LocalizedStringTableNames.walkthrough,
                                                               comment: "")
    }

    fileprivate func setCreateAccountAsLoading() {
        print("Creating account...")
        self.mCreateAccountButton.setTitle("Loading...", for: .normal)
        self.mCreateAccountButton.isUserInteractionEnabled = false

        let title = NSLocalizedString("WaitCreateAccountTitle",
                                      tableName:LocalizedStringTableNames.walkthrough,
                                      comment: "")

        HUD.show(.labeledProgress(title: title, subtitle: nil))
    }

    fileprivate func setCreateAccountAsIdle() {
        self.mCreateAccountButton.setTitle("Create a Ring account", for: .normal)
        self.mCreateAccountButton.isUserInteractionEnabled = true
        HUD.hide()
    }

    fileprivate func showDeviceAddedAlert() {
        let title = NSLocalizedString("AccountAddedTitle",
                                      tableName: LocalizedStringTableNames.walkthrough,
                                      comment: "")

        HUD.flash(.labeledSuccess(title: title, subtitle: nil), delay: alertFlashDuration)
    }

    fileprivate func showErrorAlert(_ error: AccountCreationError) {
        let alert = UIAlertController.init(title: error.title,
                                           message: error.message,
                                           preferredStyle: .alert)
        alert.addAction(UIAlertAction.init(title: "OK", style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }

    /**
     Show or hide the username field cell in function of the switch state
     */

    func toggleRegisterSwitch(_ show: Bool) {

        let usernameFieldCellIndex = 1

        if show && !mCells.contains(.usernameField) {
            self.mCells.insert(.usernameField, at: usernameFieldCellIndex)
            self.tableView.insertRows(at: [IndexPath(row: usernameFieldCellIndex, section: 0)],
                                      with: .automatic)
        } else if !show && mCells.contains(.usernameField) {
            self.mCells.remove(at: usernameFieldCellIndex)
            self.tableView.deleteRows(at: [IndexPath(row: usernameFieldCellIndex, section: 0)],
                                      with: .automatic)
        }

    }

    // MARK: TableView datasource
    fileprivate var mCells: [CreateRingAccountCellType] = [.registerPublicUsername,
                                                           .passwordNotice,
                                                           .newPasswordField,
                                                           .repeatPasswordField]

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return mCells.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

        let currentCellType = mCells[indexPath.row]

        if currentCellType == .registerPublicUsername {
            if let cell = tableView.dequeueReusableCell(withIdentifier: mSwitchCellId,
                                                        for: indexPath) as? SwitchCell {
                cell.titleLabel.text = NSLocalizedString("RegisterPublicUsername",
                                                         tableName: LocalizedStringTableNames.walkthrough,
                                                         comment: "")
                cell.titleLabel.textColor = .white

                _ = cell.registerSwitch.rx.value.bind(to: self.mAccountViewModel.registerUsername)
                    .addDisposableTo(mDisposeBag)

                return cell
            } else {
                return tableView.dequeueReusableCell(withIdentifier: mSwitchCellId, for: indexPath)
            }

        } else if currentCellType == .usernameField {
            if let cell = tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId,
                                                        for: indexPath) as? TextFieldCell {
                cell.textField.isSecureTextEntry = false
                cell.textField.placeholder = NSLocalizedString("EnterNewUsernamePlaceholder",
                                                               tableName: LocalizedStringTableNames.walkthrough,
                                                               comment: "")

                //Binds the username field value to the ViewModel
                _ = cell.textField.rx.text.orEmpty
                    .throttle(textFieldThrottlingDuration, scheduler: MainScheduler.instance)
                    .distinctUntilChanged()
                    .bind(to: self.mAccountViewModel.username)
                    .addDisposableTo(mDisposeBag)

                //Switch to new password cell when return button is touched
                _ = cell.textField.rx.controlEvent(.editingDidEndOnExit).subscribe(onNext: {
                    self.switchToCell(withType: .newPasswordField)
                }).addDisposableTo(mDisposeBag)

                _ = self.mAccountViewModel.usernameValidationMessage
                    .bind(to: cell.errorMessageLabel.rx.text)
                    .addDisposableTo(mDisposeBag)

                return cell
            } else {
                return tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId, for: indexPath)
            }

        } else if currentCellType == .passwordNotice {
            if let cell = tableView.dequeueReusableCell(withIdentifier: mTextCellId, for: indexPath) as? TextCell {
                cell.label.text = NSLocalizedString("ChooseStrongPassword",
                                                    tableName: LocalizedStringTableNames.walkthrough,
                                                    comment: "")
                return cell
            } else {
                return tableView.dequeueReusableCell(withIdentifier: mTextCellId, for: indexPath)
            }

        } else if currentCellType == .newPasswordField {
            if let cell = tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId,
                                                        for: indexPath) as? TextFieldCell {
                cell.textField.isSecureTextEntry = true
                cell.textField.placeholder = NSLocalizedString("NewPasswordPlaceholder",
                                                               tableName: LocalizedStringTableNames.walkthrough,
                                                               comment: "")

                cell.errorMessageLabel.text = NSLocalizedString("PasswordCharactersNumberError",
                                                                tableName: LocalizedStringTableNames.walkthrough,
                                                                comment: "")

                //Binds the password field value to the ViewModel
                _ = cell.textField.rx.text.orEmpty.bind(to: self.mAccountViewModel.password)
                    .addDisposableTo(mDisposeBag)

                //Binds the observer to show the error label if the field is not empty
                _ = self.mAccountViewModel.hidePasswordError.bind(to: cell.errorMessageLabel.rx.isHidden)
                    .addDisposableTo(mDisposeBag)

                //Switch to the repeat pasword cell when return button is touched
                _ = cell.textField.rx.controlEvent(.editingDidEndOnExit)
                    .subscribe(onNext: {
                        self.switchToCell(withType: .repeatPasswordField)
                    }).addDisposableTo(mDisposeBag)

                return cell
            } else {
                return tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId, for: indexPath)
            }

        } else {
            if let cell = tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId,
                                                        for: indexPath) as? TextFieldCell {
                cell.textField.isSecureTextEntry = true
                cell.textField.placeholder = NSLocalizedString("RepeatPasswordPlaceholder",
                                                               tableName: LocalizedStringTableNames.walkthrough,
                                                               comment: "")

                cell.errorMessageLabel.text = NSLocalizedString("PasswordNotMatchingError",
                                                                tableName: LocalizedStringTableNames.walkthrough,
                                                                comment: "")

                //Binds the repeat password field value to the ViewModel
                _ = cell.textField.rx.text.orEmpty.bind(to: self.mAccountViewModel.repeatPassword)
                    .addDisposableTo(mDisposeBag)

                //Binds the observer to the text field 'hidden' property
                _ = self.mAccountViewModel.hideRepeatPasswordError.bind(to: cell.errorMessageLabel.rx.isHidden)
                    .addDisposableTo(mDisposeBag)

                return cell
            } else {
                return tableView.dequeueReusableCell(withIdentifier: mTextFieldCellId, for: indexPath)
            }
        }
    }

    fileprivate func switchToCell(withType cellType: CreateRingAccountCellType) {
        if let cellIndex = self.mCells.index(of: cellType) {
            if let cell = tableView.cellForRow(at: IndexPath(row: cellIndex, section: 0))
                as? TextFieldCell {
                cell.textField.becomeFirstResponder()
            }
            self.tableView.scrollToRow(at: IndexPath(row: cellIndex, section: 0),
                                       at: .bottom, animated: false)
        }
    }
}
