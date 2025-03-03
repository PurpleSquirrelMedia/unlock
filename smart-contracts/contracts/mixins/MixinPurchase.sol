// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './MixinDisable.sol';
import './MixinKeys.sol';
import './MixinLockCore.sol';
import './MixinFunds.sol';
import './MixinErrors.sol';

/**
 * @title Mixin for the purchase-related functions.
 * @author HardlyDifficult
 * @dev `Mixins` are a design pattern seen in the 0x contracts.  It simply
 * separates logically groupings of code to ease readability.
 */
contract MixinPurchase is
  MixinErrors,
  MixinFunds,
  MixinDisable,
  MixinLockCore,
  MixinKeys
{
  event GasRefunded(address indexed receiver, uint refundedAmount, address tokenAddress);
  
  event UnlockCallFailed(address indexed lockAddress, address unlockAddress);

  // default to 0 
  uint256 internal _gasRefundValue;

  // Keep track of ERC20 price when purchased
  mapping(uint256 => uint256) internal _originalPrices;
  
  // Keep track of duration when purchased
  mapping(uint256 => uint256) internal _originalDurations;
  
  // keep track of token pricing when purchased
  mapping(uint256 => address) internal _originalTokens;

  mapping(address => uint) public referrerFees;

  /**
  * @dev Set the value/price to be refunded to the sender on purchase
  */

  function setGasRefundValue(uint256 _refundValue) external {
    _onlyLockManager();
    _gasRefundValue = _refundValue;
  }
  
  /**
  * @dev Returns value/price to be refunded to the sender on purchase
  */
  function gasRefundValue() external view returns (uint256 _refundValue) {
    return _gasRefundValue;
  }

  /**
  * Set a specific percentage of the keyPrice to be sent to the referrer while purchasing, 
  * extending or renewing a key
  * @param _referrer the address of the referrer. If set to the 0x address, any referrer will receive the fee.
  * @param _feeBasisPoint the percentage of the price to be used for this 
  * specific referrer (in basic points)
  * @notice to send a fixed percentage of the key price to all referrers, sett a percentage to `address(0)`
  */
  function setReferrerFee(address _referrer, uint _feeBasisPoint) public {
    _onlyLockManager();
    referrerFees[_referrer] = _feeBasisPoint;
  }

  /** 
  @dev internal function to execute the payments to referrers if any is set
  */
  function _payReferrer (address _referrer) internal {
    // get default value
    uint basisPointsToPay = referrerFees[address(0)];

    // get value for the referrer
    if(referrerFees[_referrer] != 0) {
      basisPointsToPay = referrerFees[_referrer];
    }
    
    // pay the referrer if necessary
    if (basisPointsToPay != 0) {
      _transfer(
        tokenAddress,
        payable(_referrer), 
        keyPrice * basisPointsToPay / BASIS_POINTS_DEN
      );
    }
  }

  /**
  * @dev Helper to communicate with Unlock (record GNP and mint UDT tokens)
  */
  function _recordKeyPurchase (uint _keyPrice, address _referrer) internal  {
    // make sure unlock is a contract, and we catch possible reverts
      if (address(unlockProtocol).code.length > 0) {
        // call Unlock contract to record GNP
        // the function is capped by gas to prevent running out of gas
        try unlockProtocol.recordKeyPurchase{gas: 300000}(_keyPrice, _referrer) 
        {} 
        catch {
          // emit missing unlock
          emit UnlockCallFailed(address(this), address(unlockProtocol));
        }
      } else {
        // emit missing unlock
        emit UnlockCallFailed(address(this), address(unlockProtocol));
      }
  }

  /**
  * @dev Purchase function
  * @param _values array of tokens amount to pay for this purchase >= the current keyPrice - any applicable discount
  * (_values is ignored when using ETH)
  * @param _recipients array of addresses of the recipients of the purchased key
  * @param _referrers array of addresses of the users making the referral
  * @param _keyManagers optional array of addresses to grant managing rights to a specific address on creation
  * @param _data arbitrary data populated by the front-end which initiated the sale
  * @notice when called for an existing and non-expired key, the `_keyManager` param will be ignored 
  * @dev Setting _value to keyPrice exactly doubles as a security feature. That way if the lock owner increases the
  * price while my transaction is pending I can't be charged more than I expected (only applicable to ERC-20 when more
  * than keyPrice is approved for spending).
  */
  function purchase(
    uint256[] memory _values,
    address[] memory _recipients,
    address[] memory _referrers,
    address[] memory _keyManagers,
    bytes[] calldata _data
  ) external payable
    returns (uint[] memory)
  {
    _lockIsUpToDate();
    if(_totalSupply +  _recipients.length > maxNumberOfKeys) {
      revert LOCK_SOLD_OUT();
    }
    if(
      (_recipients.length != _referrers.length)
      ||
      (_recipients.length != _keyManagers.length)
      ) {
      revert INVALID_LENGTH();
    }

    uint totalPriceToPay;
    uint tokenId;
    uint[] memory tokenIds = new uint[](_recipients.length);

    for (uint256 i = 0; i < _recipients.length; i++) {
      // check recipient address
      address _recipient = _recipients[i];

      // check for a non-expiring key
      if (expirationDuration == type(uint).max) {
        // create a new key
        tokenId = _createNewKey(
          _recipient,
          _keyManagers[i],
          type(uint).max
        );
      } else {
        tokenId = _createNewKey(
          _recipient,
          _keyManagers[i],
          block.timestamp + expirationDuration
        );
      }

      // price
      uint inMemoryKeyPrice = purchasePriceFor(_recipient, _referrers[i], _data[i]);
      totalPriceToPay = totalPriceToPay + inMemoryKeyPrice;

      // store values at purchase time
      _originalPrices[tokenId] = inMemoryKeyPrice;
      _originalDurations[tokenId] = expirationDuration;
      _originalTokens[tokenId] = tokenAddress;

      // store tokenIds 
      tokenIds[i] = tokenId;
      
      if(tokenAddress != address(0) && _values[i] < inMemoryKeyPrice) {
        revert INSUFFICIENT_ERC20_VALUE();
      }

      // store in unlock
      _recordKeyPurchase(inMemoryKeyPrice, _referrers[i]);

      // fire hook
      uint pricePaid = tokenAddress == address(0) ? msg.value : _values[i];
      if(address(onKeyPurchaseHook) != address(0)) {
        onKeyPurchaseHook.onKeyPurchase(
          msg.sender, 
          _recipient, 
          _referrers[i], 
          _data[i], 
          inMemoryKeyPrice, 
          pricePaid
        );
      }
    }

    // transfer the ERC20 tokens
    if(tokenAddress != address(0)) {
      IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
      token.transferFrom(msg.sender, address(this), totalPriceToPay);
    } else if(msg.value < totalPriceToPay) {
      // We explicitly allow for greater amounts of ETH or tokens to allow 'donations'
      revert INSUFFICIENT_VALUE();
    }

    // refund gas
    _refundGas();

    // send what is due to referrers
    for (uint256 i = 0; i < _referrers.length; i++) { 
      _payReferrer(_referrers[i]);
    }

    return tokenIds;
  }

  /**
  * @dev Extend function
  * @param _value the number of tokens to pay for this purchase >= the current keyPrice - any applicable discount
  * (_value is ignored when using ETH)
  * @param _tokenId id of the key to extend
  * @param _referrer address of the user making the referral
  * @param _data arbitrary data populated by the front-end which initiated the sale
  * @dev Throws if lock is disabled or key does not exist for _recipient. Throws if _recipient == address(0).
  */
  function extend(
    uint _value,
    uint _tokenId,
    address _referrer,
    bytes calldata _data
  ) 
    public 
    payable
  {
    _lockIsUpToDate();
    _isKey(_tokenId);

    // extend key duration
    _extendKey(_tokenId, 0);

    // transfer the tokens
    uint inMemoryKeyPrice = purchasePriceFor(ownerOf(_tokenId), _referrer, _data);

    // process in unlock
    _recordKeyPurchase(inMemoryKeyPrice, _referrer);

    if(tokenAddress != address(0)) {
      if(_value < inMemoryKeyPrice) {
        revert INSUFFICIENT_ERC20_VALUE();
      }
      IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
      token.transferFrom(msg.sender, address(this), inMemoryKeyPrice);
    } else if(msg.value < inMemoryKeyPrice) {
      // We explicitly allow for greater amounts of ETH or tokens to allow 'donations'
      revert INSUFFICIENT_VALUE();
    }

    // if params have changed, then update them
    if(_originalPrices[_tokenId] != inMemoryKeyPrice) {
      _originalPrices[_tokenId] = inMemoryKeyPrice;
    }
    if(_originalDurations[_tokenId] != expirationDuration) {
      _originalDurations[_tokenId] = expirationDuration;
    }
    if(_originalTokens[_tokenId] != tokenAddress) {
      _originalTokens[_tokenId] = tokenAddress;
    }

    // refund gas (if applicable)
    _refundGas();

    // send what is due to referrer
    _payReferrer(_referrer);
  }

  /**
  * Renew a given token
  * @notice only works for non-free, expiring, ERC20 locks
  * @param _tokenId the ID fo the token to renew
  * @param _referrer the address of the person to be granted UDT
  */
  function renewMembershipFor(
    uint _tokenId,
    address _referrer
  ) public {
    _lockIsUpToDate();
    _isKey(_tokenId);

    // check the lock
    if(_originalDurations[_tokenId] == type(uint).max || tokenAddress == address(0)) {
      revert NON_RENEWABLE_LOCK();
    }

    // make sure duration and pricing havent changed  
    uint keyPrice = purchasePriceFor(ownerOf(_tokenId), _referrer, '');
    if(
      _originalPrices[_tokenId] != keyPrice
      ||
      _originalDurations[_tokenId] != expirationDuration
      || 
      _originalTokens[_tokenId] != tokenAddress
    ) {
      revert LOCK_HAS_CHANGED();
    }

    // make sure key is ready for renewal
    if(isValidKey(_tokenId)) {
      revert NOT_READY_FOR_RENEWAL();
    }

    // extend key duration
    _extendKey(_tokenId, 0);

    // store in unlock
    _recordKeyPurchase(keyPrice, _referrer);

    // transfer the tokens
    IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
    token.transferFrom(ownerOf(_tokenId), address(this), keyPrice);

    // refund gas if applicable
    _refundGas();

    // send what is due to referrer
    _payReferrer(_referrer);
  }

  /**
   * @notice returns the minimum price paid for a purchase with these params.
   * @dev minKeyPrice considers any discount from Unlock or the OnKeyPurchase hook
   */
  function purchasePriceFor(
    address _recipient,
    address _referrer,
    bytes memory _data
  ) public view
    returns (uint minKeyPrice)
  {
    if(address(onKeyPurchaseHook) != address(0))
    {
      minKeyPrice = onKeyPurchaseHook.keyPurchasePrice(msg.sender, _recipient, _referrer, _data);
    }
    else
    {
      minKeyPrice = keyPrice;
    }
  }

  /**
   * Refund the specified gas amount and emit an event
   * @notice this does sth only if `_gasRefundValue` is non-null
   */
  function _refundGas() internal {
    if (_gasRefundValue != 0) { 
      if(tokenAddress != address(0)) {
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        // send tokens to refun gas
        token.transfer(msg.sender, _gasRefundValue);
      } else {
        (bool success, ) = msg.sender.call{value: _gasRefundValue}("");
        if(!success) {
          revert GAS_REFUND_FAILED();
        }
      }
      emit GasRefunded(msg.sender, _gasRefundValue, tokenAddress);
    }
  }

  // decreased from 1000 to 997 when added mappings for initial purchases pricing and duration on v10 
  // decreased from 997 to 996 when added the `referrerFees` mapping on v11
  uint256[996] private __safe_upgrade_gap;
}
