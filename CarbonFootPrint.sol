// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

contract CarbonFootprint {

    struct Company {
        uint32 id;
        string CompanyName;
        uint32 trucks;
        uint32 avgdistance;
        uint32 trucksweigth;
        uint32 cargoweight;
    }
    
    enum TruckType {CTT, ALMA}

    TruckType choice;

    uint16 CLCV = 143;
    uint16 CHCV = 307;

    Company[] private companies;

    function cfpcalculator(uint32 trucks_weigth, uint32 cargo_weight, uint32 avg_distance, uint32 no_of_trucks) external view returns(uint256) {

        uint256 total_weigth = trucks_weigth + cargo_weight;
        uint256 tonkm = total_weigth * avg_distance * no_of_trucks;

        uint256 cfpvalues;

        if (choice == TruckType.CTT)
        {
            cfpvalues = CLCV * tonkm;
            return cfpvalues / 1000000;
        }
        else {
            cfpvalues = CHCV * tonkm;
            return cfpvalues / 1000000;
        }
    }
}
