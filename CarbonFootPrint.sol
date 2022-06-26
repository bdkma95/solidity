// SPDX-License-Identifier: MIT

pragma solidity ^0.8.15;

contract CarbonFootPrint {
    // Structures - Entities Implementation
    struct Product {
        uint32 id;
        string name;
        string description;
        bool intermediate;
        uint32 idOrganization;
        uint32 idUnit;
        uint32 [] productFootPrints;
    }

    struct ProductFootPrint {
        uint32 id;
        uint32 co2eq;
        uint16 exp;
        uint32 idProduct;
        uint32 year;
        string month;
        uint32 idMonthlyActivity;
    }

    struct MonthlyActivity {
        uint32 id;
        string description;
        uint32 co2eq;
        uint16 exp;
        string month;
        uint32 [] productQuantities;
        uint32 output;
        uint32 finalProductQuantity;
        uint32 idOrganization;
        uint32 idUnit;
        uint32 idYear;
        address idUser;
        uint32 [] productionCosts;
    }

    mapping(uint32 => Product) public products;
    uint32 public productsCount;

    mapping(uint32 => MonthlyActivity) public mActivity;
    uint32 public mActivityCount;

    mapping(uint32 => Organization) public organizations;
    uint32 public organizationsCount;

    mapping(uint32 => MonthlyFixCost) public mFixCostsCount;
    uint32 public monthlyFixCostsCount;

    mapping(uint32 => Unit) public units;
    uint32 public unitsCount;

    mapping(uint32 => ProductCost) public productsCosts;
    uint32 public productCostsCount;

    mapping(uint32 => CostType) public costsTypes;
    uint32 public costsTypesCount;

    mapping(uint32 => ProductFootPrint) public productFootPrints;
    uint32 public pFootPrintCount;

    mapping(uint32 => ProductQuantity) public productsQuantities;
    uint32 public productsQuantitiesCount;

    event registerUserEvent(address indexed _candidatesAddress);

    constructor() public {
        users[msg.sender] = User(msg.sender, 0, true);
        arrayUsers.push(msg.sender);

        // Initializa units
        addUnit("tonne", "t", 10, 0, 1, false);
        addUnit("kilogram", "kg", 10, 3, 1, true);
        addUnit("gram", "g", 10, 6, 1, true);
        addUnit("miligram", "mg", 10, 9, 1, true);
    }

    function addUser(address _userResp, address _user, uint16 _tipo, uint32 _organization) public {
        require(users[_user].user_add == address(0), "User already registered");
        if(_tipo == 0 || _tipo == 1) {
            require(users[_userResp].tipo == 0, "You need admin permissions");
        }else if(_tipo == 2) {
            require(users[_userResp].tipo == 1, "You need organization admin permissions");
        }

        users[_user] = User(_user, _tipo, true);
        arrayUsers.push(_user);
        userOrganizations[_user].push(_organization);

        emit registerUserEvent(_user);
    }

    // Add New Product Function
    function addProduct(string memory _name, string memory _description, bool _intermediate, uint32 _org, uint32 _unit, uint32 [] memory _footPrints) public {
        bool exist = false;
        require(users[msg.sender].idOrganization == _org, "You need to belong to the organization");
        require(organizations[_org].id!= uint32(0), "Organization doesn't exist");

        for(uint32 i=1; i <= productsCount; i++) {
            string memory name = products[i].name;
            if(keccak256(abi.encodePacked(_name))) {
                exist = true;
            }
        }

        require(!exist, "Product already registered");

        productsCount++;
        products[productsCount] =
            Product(productsCount, _name, _description, units[_unit].initials, _intermediate, _org, _unit, _footPrints);
        organizations[_org].products.push(productsCount);
    }

    // Add New Product Footprint Function
    function addFootPrintProd(uint32 _co2eq, uint16 _exp, uint32 _idProd, uint32 _year, string memory _month, uint32 _idMa) public {
        require(users[msg.sender].idOrganization == products[_idProd].idOrganization, "The product doesn't belong to your organization");
        require(products[_idProd].id != uint32(0), "Product doesn't exist");

        pFootPrintCount++;
        productFootPrints[pFootPrintCount] = 
            ProductFootPrint(pFootPrintCount, _co2eq, _exp, idProd, _year, _month, _idMa);
        products[_idProd].productFootPrints.push(pFootPrintCount);
    }
}
