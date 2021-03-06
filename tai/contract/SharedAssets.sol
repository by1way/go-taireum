pragma solidity 0.4.24;

contract SharedAssets {
    
    struct Asset {
        bytes32 id;                 //资产ID（考虑用owner、userHash、timestamp算一个hash）
        address addr;               //资产发起人账户地址
        bytes32 userHash;           //用户hash
        uint timestamp;             //时间戳
        uint interset;              //日利率
        uint amount;                //额度
        uint state;                 //资产状态  0-不存在 1-开始投标 2-投标结束 3-选标结束 4-收款结束 5-还款结束
        mapping(address => Bid) bids;
    }

    struct Bid {
        uint timestamp;             //时间戳
        uint interset;              //日利率
        uint amount;                //额度
        uint deposit;               //保证金
        uint state;                 //资产状态  0-不存在 1-已投标 2-已中标 3-未中标 4-已放款 5-已没收保证金
    }
    
    mapping(bytes32 => Asset) public assets;
    mapping(address => uint) public balance;        //账户可用余额，可随时提取
    mapping(address => uint) public deposit;        //账户保证金，已冻结，不可提取
    mapping(bytes32 => address[]) public addrs;

    event AssetAdded(bytes32 _id, bytes32 _userHash, uint _interset, uint _amount);
    event BidAdded(bytes32 _id, address _addr, uint _interset, uint _amount, uint _deposit);
    event AssetStateChanged(bytes32 _id, uint _state);
    event BidChoosed(bytes32 _id, address[] _addrs, uint[] _states);
    event Loaned(bytes32 _id, address _addr);

    //将用户转账金额存到balance中，可通过withdraw方法取回余额
    function() public payable {
        balance[msg.sender] = balance[msg.sender] + msg.value;
    }

    function withdraw() public returns(bool) {
        msg.sender.transfer(balance[msg.sender]);
        return true;
    }

    //添加资产
    function addAsset(bytes32 _id, bytes32 _userHash, uint _interset, uint _amount) public returns(bool) {
        require(assets[_id].state == uint(0), "asset already added");
        assets[_id] = Asset({id:_id,addr:msg.sender,userHash:_userHash,timestamp:now,interset:_interset,amount:_amount,state:uint(1)});
        emit AssetAdded(_id, _userHash, _interset, _amount);
        return true;
    }

    //投标需要保证金，确保用户不会胡乱出价。
    //资产发起人可根据利率、保证金、放款额度来选标。
    //投标成功后会将保证金冻结。投标前需要确保有足够的账户余额，否则会报错
    function addBid(bytes32 _id, uint _interset, uint _amount, uint _deposit) public returns(bool) {
        require(assets[_id].state == uint(1), "asset not exist or bid already ended");
        require(assets[_id].bids[msg.sender].state == uint(0), "bid already added");
        require(balance[msg.sender] >= _deposit, "not enough balance");
        balance[msg.sender] = balance[msg.sender] - _deposit;
        deposit[msg.sender] = deposit[msg.sender] + _deposit;
        assets[_id].bids[msg.sender] = Bid({timestamp:now,interset:_interset,amount:_amount,deposit:_deposit,state:uint(1)});
        addrs[_id].push(msg.sender);
        emit BidAdded(_id, msg.sender, _interset, _amount, _deposit);
        return true;
    }

    //改变资产状态，可由资产发起人调用，也可由别的函数调用。
    //当资产状态为4时，收款结束。此时会遍历所有参与者，将已中标但未放款的用户的保证金罚没。
    function changeAssetState(bytes32 _id, uint _state) public returns(bool) {
        require(assets[_id].addr == msg.sender, "you have no rignt to change this asset's state");
        require(assets[_id].state < _state, "state larger than or equal to asset's state");
        if (_state == uint(4)) {
            require(now - assets[_id].timestamp > 24*3600, "less than 24h");
            for (uint i = 0; i < addrs[_id].length; i++) {
                if (assets[_id].bids[addrs[_id][i]].state == uint(2)) {
                    balance[msg.sender] = balance[msg.sender] + assets[_id].bids[addrs[_id][i]].deposit;
                    deposit[addrs[_id][i]] = deposit[addrs[_id][i]] - assets[_id].bids[addrs[_id][i]].deposit;
                    assets[_id].bids[addrs[_id][i]].state = uint(5);
                }
            }
        }
        assets[_id].state = _state;
        emit AssetStateChanged(_id, _state);
        return true;
    }

    //资产发起人选标
    //遍历所有投标，将未中标的投标者的押金如数退还
    function chooseBid(bytes32 _id, address[] _addrs, uint[] _states) public returns(bool) {
        require(assets[_id].addr == msg.sender, "you have no rignt to change this asset's state");
        require(assets[_id].state == uint(2), "asset not exist or bid not ended");
        require(addrs[_id].length == _addrs.length, "addrs length not equel to asset's bidders addrs length");
        for (uint i = 0; i < _addrs.length; i++) {
            if (_states[i] != uint(2)) {
                balance[_addrs[i]] = balance[_addrs[i]] + assets[_id].bids[_addrs[i]].deposit;
                deposit[_addrs[i]] = deposit[_addrs[i]] - assets[_id].bids[_addrs[i]].deposit;
                assets[_id].bids[_addrs[i]].state = uint(3);
            } else {
                assets[_id].bids[_addrs[i]].state = uint(2);
            }
        }
        changeAssetState(_id, uint(3));
        emit BidChoosed(_id, _addrs, _states);
        return true;
    }

    //中标者放款，放款前需要确保有足够的账户余额，否则会报错
    //将中标者放款金额转到资产发起人账户余额中
    function load(bytes32 _id) public returns(bool) {
        require(balance[msg.sender] >= assets[_id].bids[msg.sender].amount - assets[_id].bids[msg.sender].deposit, "not enough balance");
        balance[assets[_id].addr] = balance[assets[_id].addr] + assets[_id].bids[msg.sender].amount;
        deposit[msg.sender] = deposit[msg.sender] - assets[_id].bids[msg.sender].deposit;
        balance[msg.sender] = balance[msg.sender] - (assets[_id].bids[msg.sender].amount - assets[_id].bids[msg.sender].deposit);
        assets[_id].bids[msg.sender].state = uint(4);
        emit Loaned(_id, msg.sender);
        return true;
    }

    //资产发起人还款，还款前需要确保有足够的账户余额，否则会报错
    //遍历所有已放款的投标，根据利率和借款天数计算还款金额，并将还款金额打到中标者账户中
    function repayment(bytes32 _id) public returns(bool) {
        require(assets[_id].addr == msg.sender, "you can't repay this asset");
        uint repayAmount = 0;
        for (uint i = 0; i < addrs[_id].length; i++) {
            if (assets[_id].bids[addrs[_id][i]].state == uint(4)) {
                repayAmount = ((now - assets[_id].timestamp)/86400)*assets[_id].bids[addrs[_id][i]].amount*(assets[_id].bids[addrs[_id][i]].interset/1000);
                require(balance[msg.sender] >= repayAmount, "not enough balance");
                balance[msg.sender] = balance[msg.sender] - repayAmount;
                balance[addrs[_id][i]] = balance[addrs[_id][i]] + repayAmount;
                assets[_id].bids[addrs[_id][i]].state == uint(5);
            }
        }
        changeAssetState(_id, uint(5));
        return true;
    }
    
}