// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
    Interfaces for external token standards.
*/
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/*
    Minimal soul-bound token (SBT) implementation.
*/
contract SoulBoundToken {
    string public name = "WillSBT";
    string public symbol = "WILL";
    uint256 public tokenCounter;
    mapping(uint256 => address) public ownerOfToken;
    mapping(address => uint256) public tokenOfOwner;
    event Mint(address indexed to, uint256 tokenId);

    function mint(address to) internal returns (uint256) {
        tokenCounter += 1;
        uint256 newTokenId = tokenCounter;
        ownerOfToken[newTokenId] = to;
        tokenOfOwner[to] = newTokenId;
        emit Mint(to, newTokenId);
        return newTokenId;
    }
}

/*
    Main DigitalWill contract – supports multiple wills per user, multiple beneficiaries, 
    multiple oracle addresses for death verification, and both on-chain and off-chain assets.
    Once a majority of designated oracles verify death, asset distribution occurs automatically.
*/
contract DigitalWill is SoulBoundToken {
    
    enum AssetType { ETH, ERC20, ERC721, OffChain }
    
    struct Asset {
        AssetType assetType;
        address tokenAddress; // For ERC20/ERC721 (not used for OffChain).
        uint256 tokenId;      // For ERC721 tokens.
        uint256 amount;       // For ETH and ERC20 tokens.
        string metadataURI;   // For off-chain assets.
    }
    
    struct Beneficiary {
        address wallet;  
        uint256 share;   // Share in basis points (total must equal 100000).
    }
    
    
    struct Oracle {
        address wallet;
        string aadhaarNumber;
    }
    
    
    struct Will {
        uint256 id;
        address owner;
        Beneficiary[] beneficiaries;
        Asset[] assets;
        bool deathVerified;
        bool assetsTransferred;
        Oracle[] deathOracles;  
        uint256 deathApprovalCount;
        uint256 deathApprovalThreshold; 
       
        uint256 ethDeposited;
    }
    
    
    mapping(uint256 => Will) public wills;
    
    mapping(address => uint256[]) public ownerWills;
    
    mapping(uint256 => mapping(address => bool)) public deathApprovals;
    
    uint256 public willCounter;
    address public admin;
    uint256 public constant MAX_BENEFICIARIES = 10;
    
    event WillCreated(address indexed owner, uint256 indexed willId);
    event OracleApprovalReceived(uint256 indexed willId, address indexed oracle);
    event DeathVerified(uint256 indexed willId);
    event AssetsClaimed(uint256 indexed willId);
    event OffChainAssetClaim(uint256 indexed willId, address beneficiary, string metadataURI);
    event WillRevoked(address indexed owner, uint256 indexed willId);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }
    
    constructor() payable {
        admin = msg.sender;
    }
    
    /*
       Create a new will with beneficiaries, assets, and designated oracle addresses.
       Returns the new will's ID.
    */
    function createWill(
        address[] calldata _beneficiaries,
        uint256[] calldata _shares,
        Asset[] calldata _assets,
        address[] calldata _oracles,
        string[] calldata _aadhaarNumbers
    ) external payable returns (uint256) {
        require(_beneficiaries.length > 0, "No beneficiaries specified");
        require(_beneficiaries.length <= MAX_BENEFICIARIES, "Too many beneficiaries");
        require(_beneficiaries.length == _shares.length, "Beneficiaries and shares count mismatch");
        require(_oracles.length > 0, "At least one oracle required");
        require(_oracles.length == _aadhaarNumbers.length, "Oracle and Aadhaar count mismatch");

        uint256 totalShares = 0;
        willCounter++;
        uint256 newWillId = willCounter;
        
        
        Will storage newWill = wills[newWillId];
        newWill.id = newWillId;
        newWill.owner = msg.sender;
        newWill.deathVerified = false;
        newWill.assetsTransferred = false;
        
        
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            require(_beneficiaries[i] != address(0), "Invalid beneficiary address");
            totalShares += _shares[i];
            newWill.beneficiaries.push(Beneficiary(_beneficiaries[i], _shares[i]));
        }
        require(totalShares == 100000, "Total shares must sum to 100000 (100%)");

        
        for (uint256 i = 0; i < _oracles.length; i++) {
            require(_oracles[i] != address(0), "Invalid oracle address");
            require(bytes(_aadhaarNumbers[i]).length > 0, "Empty Aadhaar number");
            newWill.deathOracles.push(Oracle(_oracles[i], _aadhaarNumbers[i]));
        }
       
        newWill.deathApprovalThreshold = (newWill.deathOracles.length / 2) + 1;
        
        
        uint256 totalETHRequired = 0;
        for (uint i = 0; i < _assets.length; i++) {
            Asset memory asset = _assets[i];
            if (asset.assetType == AssetType.ETH) {
               
                totalETHRequired += asset.amount;
            }
            newWill.assets.push(asset);
        }
      
        require(msg.value >= totalETHRequired, "Insufficient ETH sent");
        newWill.ethDeposited = totalETHRequired;
        
       
        ownerWills[msg.sender].push(newWillId);
        mint(msg.sender);
        emit WillCreated(msg.sender, newWillId);
        return newWillId;
    }
    
    /*
       Designated oracles call this function to verify death for a specific will.
       Once the threshold is reached, the will is marked as deceased and assets are distributed automatically.
    */
    function oracleVerifyDeath(uint256 _willId) external {
        Will storage userWill = wills[_willId];
        require(userWill.owner != address(0), "Will does not exist");
        require(!userWill.deathVerified, "Death already verified");
        
        bool isDesignatedOracle = false;
        for (uint256 i = 0; i < userWill.deathOracles.length; i++) {
            if (userWill.deathOracles[i].wallet == msg.sender) {
                isDesignatedOracle = true;
                break;
            }
        }
        require(isDesignatedOracle, "Caller is not a designated oracle");
        
        
        require(!deathApprovals[_willId][msg.sender], "Oracle already approved");
        deathApprovals[_willId][msg.sender] = true;
        userWill.deathApprovalCount++;
        emit OracleApprovalReceived(_willId, msg.sender);
        
        
        if (userWill.deathApprovalCount >= userWill.deathApprovalThreshold) {
            userWill.deathVerified = true;
            emit DeathVerified(_willId);
            _distributeAssets(_willId);
        }
    }
    
    /*
       Internal function to distribute assets automatically to all beneficiaries.
       ETH and ERC20 tokens are split proportionally based on beneficiary shares.
       ERC721 tokens can only be transferred if there is a sole beneficiary.
    */
    function _distributeAssets(uint256 _willId) internal {
        Will storage userWill = wills[_willId];
        require(userWill.deathVerified, "Death not verified");
        require(!userWill.assetsTransferred, "Assets already transferred");
        
        for (uint i = 0; i < userWill.assets.length; i++) {
            Asset memory asset = userWill.assets[i];
            if (asset.assetType == AssetType.ETH) {
                
                uint256 availableETH = userWill.ethDeposited;
                require(availableETH > 0, "No ETH available for distribution");
                
                for (uint256 j = 0; j < userWill.beneficiaries.length; j++) {
                    uint256 allocatedETH = (availableETH * userWill.beneficiaries[j].share) / 100000;
                    if (allocatedETH > 0) {
                        payable(userWill.beneficiaries[j].wallet).transfer(allocatedETH);
                    }
                }
            } else if (asset.assetType == AssetType.ERC20) {
                uint256 availableTokens = IERC20(asset.tokenAddress).balanceOf(address(this));
                require(availableTokens >= asset.amount, "Insufficient ERC20 balance in contract");
                for (uint256 j = 0; j < userWill.beneficiaries.length; j++) {
                    uint256 allocatedTokens = (asset.amount * userWill.beneficiaries[j].share) / 100000;
                    if (allocatedTokens > 0) {
                        bool success = IERC20(asset.tokenAddress).transfer(userWill.beneficiaries[j].wallet, allocatedTokens);
                        require(success, "ERC20 transfer failed");
                    }
                }
            } else if (asset.assetType == AssetType.ERC721) {
                
                require(userWill.beneficiaries.length == 1 && userWill.beneficiaries[0].share == 100000, "ERC721 tokens require sole beneficiary");
                IERC721(asset.tokenAddress).safeTransferFrom(address(this), userWill.beneficiaries[0].wallet, asset.tokenId);
            } else if (asset.assetType == AssetType.OffChain) {
                
                for (uint256 j = 0; j < userWill.beneficiaries.length; j++) {
                    emit OffChainAssetClaim(_willId, userWill.beneficiaries[j].wallet, asset.metadataURI);
                }
            }
        }
        userWill.assetsTransferred = true;
        emit AssetsClaimed(_willId);
    }
    
    /*
       Revoke a specific will if death has not been verified.
       All assets will be returned to the will owner.
    */
    function revokeWill(uint256 _willId) external {
        Will storage userWill = wills[_willId];
        require(userWill.owner == msg.sender, "Not will owner");
        require(!userWill.deathVerified, "Death already verified");
        
        for (uint i = 0; i < userWill.assets.length; i++) {
            Asset memory asset = userWill.assets[i];
            if (asset.assetType == AssetType.ETH) {
                
                uint256 availableETH = address(this).balance;
                require(availableETH >= asset.amount, "Not enough ETH in contract");
                payable(msg.sender).transfer(asset.amount);
            } else if (asset.assetType == AssetType.ERC20) {
                uint256 availableTokens = IERC20(asset.tokenAddress).balanceOf(address(this));
                require(availableTokens >= asset.amount, "Insufficient ERC20 balance in contract");
                bool success = IERC20(asset.tokenAddress).transfer(msg.sender, asset.amount);
                require(success, "ERC20 transfer failed");
            } else if (asset.assetType == AssetType.ERC721) {
                
                require(IERC721(asset.tokenAddress).ownerOf(asset.tokenId) == address(this), "Contract not owner of ERC721");
                IERC721(asset.tokenAddress).safeTransferFrom(address(this), msg.sender, asset.tokenId);
            }
        }
        
       
        delete wills[_willId];
       
        emit WillRevoked(msg.sender, _willId);
    }
    
    function updateAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid admin address");
        admin = _newAdmin;
    }
    
   
    function getWillOracles(uint256 _willId) external view returns (Oracle[] memory) {
        Will storage userWill = wills[_willId];
        require(userWill.owner != address(0), "Will does not exist");
        return userWill.deathOracles;
    }

    function getOracleCount(uint256 _willId) external view returns (uint256) {
        Will storage userWill = wills[_willId];
        require(userWill.owner != address(0), "Will does not exist");
        return userWill.deathOracles.length;
    }

    function getOracleDetails(uint256 _willId, uint256 _oracleIndex) external view returns (address wallet, string memory aadhaarNumber, bool hasApproved) {
        Will storage userWill = wills[_willId];
        require(userWill.owner != address(0), "Will does not exist");
        require(_oracleIndex < userWill.deathOracles.length, "Oracle index out of bounds");
        
        Oracle memory oracle = userWill.deathOracles[_oracleIndex];
        return (
            oracle.wallet,
            oracle.aadhaarNumber,
            deathApprovals[_willId][oracle.wallet]
        );
    }
    
    receive() external payable {}
    fallback() external payable {}  
}
