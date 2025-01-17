// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract ChildContract is ERC721Enumerable, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using Strings for uint256;

    Counters.Counter private supply;

    string public uriPrefix = "";
    string public uriSuffix = ".json";
    string public hiddenMetadataUri;

    uint256 public cost = 0.01 ether;
    uint256 public maxSupply = 10000;
    uint256 public maxMintAmountPerTx = 5;

    bool public paused = true;
    bool public revealed = false;

    struct Time {
        uint startTime;
        uint deadline;
    }

    mapping(string => Time) public promoCodes;

    constructor(
        string memory _collectionName,
        string memory _collectionSymbol,
        string memory _collectionDescription
    ) ERC721(_collectionName, _collectionSymbol) {
        hiddenMetadataUri = "ipfs://__CID__/hidden.json";
    }

    modifier mintCompliance(uint256 _mintAmount) {
        require(_mintAmount > 0 && _mintAmount <= maxMintAmountPerTx, "Invalid mint amount!");
        require(supply.current() + _mintAmount <= maxSupply, "Max supply exceeded!");
        _;
    }

    function totalSupply() public view returns (uint256) {
        return supply.current();
    }

    function mint(uint256 _mintAmount) public payable mintCompliance(_mintAmount) {
        require(!paused, "The contract is paused!");
        require(msg.value >= cost * _mintAmount, "Insufficient funds!");

        _mintLoop(msg.sender, _mintAmount);
    }

    function mintForAddress(uint256 _mintAmount, address _receiver) public mintCompliance(_mintAmount) onlyOwner {
        _mintLoop(_receiver, _mintAmount);
    }

    function walletOfOwner(address _owner) public view returns (uint256[] memory) {
        uint256 ownerTokenCount = balanceOf(_owner);
        uint256[] memory ownedTokenIds = new uint256[](ownerTokenCount);

        for (uint256 i = 0; i < ownerTokenCount; i++) {
            ownedTokenIds[i] = tokenOfOwnerByIndex(_owner, i);
        }

        return ownedTokenIds;
    }

    function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
        require(_exists(_tokenId), "ERC721Metadata: URI query for nonexistent token");

        if (!revealed) {
            return hiddenMetadataUri;
        }

        return string(abi.encodePacked(uriPrefix, _tokenId.toString(), uriSuffix));
    }

    function setRevealed(bool _state) public onlyOwner {
        revealed = _state;
    }

    function setCost(uint256 _cost) public onlyOwner {
        cost = _cost;
    }

    function setMaxMintAmountPerTx(uint256 _maxMintAmountPerTx) public onlyOwner {
        maxMintAmountPerTx = _maxMintAmountPerTx;
    }

    function setPaused(bool _state) public onlyOwner {
        paused = _state;
    }

    function withdraw() public onlyOwner nonReentrant {
        (bool os, ) = payable(owner()).call{value: address(this).balance}("");
        require(os, "Withdraw failed");
    }

    function setCodePromo(string memory _newCodePromo, uint _startTime, uint _endTime) public onlyOwner {
        promoCodes[_newCodePromo] = Time({ startTime: _startTime, deadline: _endTime });
    }

    function getCodePromo(string memory _code) public view returns (Time memory) {
        return promoCodes[_code];
    }

    function _mintLoop(address _receiver, uint256 _mintAmount) internal {
        for (uint256 i = 0; i < _mintAmount; i++) {
            supply.increment();
            _safeMint(_receiver, supply.current());
        }
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return uriPrefix;
    }
}
