// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

contract SupplyChainTracking {

  /* set owner */
    address public owner;

  /* Add a variable called skuCount to track the most recent sku # */
    uint skuCount;
  /* Add a line that creates a public mapping that maps the SKU (a number) to an Item.
    Call this mappings items
  */
    mapping (uint => Item) public items;

  /* Add a line that creates an enum called State. This should have 4 states
    ForSale
    Sold
    Shipped
    Received
    (declaring them in this order is important for testing)
  */
    enum State {ForSale, Sold, Shipped, Received}

  /* Create a struct named Item.
    Here, add a name, sku, price, state, seller, and buyer
    We've left you to figure out what the appropriate types are,
    if you need help you can ask around :)
  */
    struct Item {
        string name;
        uint sku;
        uint price;
        State state;
        address seller;
        address buyer;
    }

  /* Create 4 events with the same name as each possible State (see above)
    Each event should accept one argument, the sku*/
    event forSale(uint indexed sku);
    event Sold(uint indexed sku);
    event Shipped(uint indexed sku);
    event Received(uint indexed sku);

  /* Create a modifer that checks if the msg.sender is the owner of the contract */
    modifier checkOwnership() {
        require(owner == msg.sender);
        _;
    }

    modifier verifyCaller(address _address) {require (msg.sender == _address,"The call is not verified"); _;}

    modifier paidEnough(uint _price) {require(msg.value >= _price,"There is not enough price sent"); _;}
    modifier checkValue(uint _sku) {
        //refund them after pay for item (why it is before, _ checks for logic before func)
        _;
        uint _price = items[_sku].price;
        uint amountToRefund = msg.value - _price;
        payable(items[_sku].buyer).transfer(amountToRefund);
    }

  /* For each of the following modifiers, use what you learned about modifiers
  to give them functionality. For example, the forSale modifier should require
  that the item with the given sku has the state ForSale. */
    modifier ForSale(uint _sku) {require(items[_sku].state == State.ForSale, "The item state is not for sale"); _;}
    modifier sold(uint _sku) {require(items[_sku].state == State.Sold, "The item state is not sold"); _;} 
    modifier shipped(uint _sku) {require(items[_sku].state == State.Shipped, "The item state is not shipped"); _;}
    modifier received(uint _sku) {require(items[_sku].state == State.Received,"The item state is not recieved"); _;}
 
    constructor() {
    /* Here, set the owner as the person who instantiated the contract
      and set your skuCount to 0. */
        owner = msg.sender;
        skuCount = 0; 
    }

    function addItem(string calldata _name, uint _price) public returns(bool) {
        emit forSale(skuCount);
        items[skuCount] = Item({name: _name, sku: skuCount, price: _price, state: State.ForSale, seller: msg.sender, buyer: address(0)});
        skuCount = skuCount + 1;
        return true;
    }

  /* Add a keyword so the function can be paid. This function should transfer money
    to the seller, set the buyer as the person who called this transaction, and set the state
    to Sold. Be careful, this function should use 3 modifiers to check if the item is for sale,
    if the buyer paid enough, and check the value after the function is called to make sure the buyer is
    refunded any excess ether sent. Remember to call the event associated with this function!*/

    function buyItem(uint sku)
    public payable ForSale(sku) paidEnough(items[sku].price) checkValue(sku) 
   {
        payable(items[sku].seller).transfer(items[sku].price);
        items[sku].buyer = msg.sender;
        items[sku].state = State.Sold;
        emit Sold(sku);
    }

  /* Add 2 modifiers to check if the item is sold already, and that the person calling this function
  is the seller. Change the state of the item to shipped. Remember to call the event associated with this function!*/
    function shipItem(uint sku)
    public sold(sku) verifyCaller(items[sku].seller)
    {
        items[sku].state = State.Shipped;
        emit Shipped(sku);
    }

  /* Add 2 modifiers to check if the item is shipped already, and that the person calling this function
  is the buyer. Change the state of the item to received. Remember to call the event associated with this function!*/
    function receiveItem(uint sku)
    public shipped(sku) verifyCaller(items[sku].buyer)
    {
        items[sku].state = State.Received;
        emit Received(sku);
    }
}
