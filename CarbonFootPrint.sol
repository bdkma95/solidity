// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

contract CarbonFootprint {
    struct Company {
        uint32 id;             // Unique company ID
        string name;           // Company name
        uint32 trucks;         // Number of trucks owned
        uint32 averageDistance; // Average distance traveled by trucks (in km)
        uint32 truckWeight;    // Weight of an individual truck (in kg)
        uint32 cargoWeight;    // Weight of the cargo (in kg)
    }

    // Truck emission coefficients (gCO2 per ton-km)
    uint16 private constant CLCV = 246; // Coefficient for Light Commercial Trucks
    uint16 private constant CHCV = 602; // Coefficient for Heavy Commercial Trucks

    enum TruckType { CTT, ALMA } // Truck Types
    TruckType public truckType; // Default truck type for calculations

    Company[] private companies; // List of companies

    /**
     * @notice Sets the truck type to be used for calculations.
     * @param _truckType The truck type (0 for CTT, 1 for ALMA).
     */
    function setTruckType(TruckType _truckType) external {
        truckType = _truckType;
    }

    /**
     * @notice Calculates the carbon footprint for a given set of parameters.
     * @param truckWeight Weight of an individual truck (in kg).
     * @param cargoWeight Weight of the cargo (in kg).
     * @param avgDistance Average distance traveled by the trucks (in km).
     * @param numberOfTrucks Number of trucks in operation.
     * @param selectedTruckType The type of truck used (0 for CTT, 1 for ALMA).
     * @return Carbon footprint in metric tons of CO2.
     */
    function calculateCarbonFootprint(
        uint32 truckWeight,
        uint32 cargoWeight,
        uint32 avgDistance,
        uint32 numberOfTrucks,
        TruckType selectedTruckType
    ) external pure returns (uint256) {
        // Calculate total weight (in tons) and ton-km
        uint256 totalWeightTons = (truckWeight + cargoWeight) / 1000;
        uint256 tonKm = totalWeightTons * avgDistance * numberOfTrucks;

        // Determine emission coefficient based on truck type
        uint16 emissionCoefficient = selectedTruckType == TruckType.CTT ? CLCV : CHCV;

        // Calculate carbon footprint and return the result in metric tons
        uint256 carbonFootprint = (emissionCoefficient * tonKm) / 1_000_000;
        return carbonFootprint;
    }

    /**
     * @notice Adds a new company to the system.
     * @param id Unique ID for the company.
     * @param name Name of the company.
     * @param trucks Number of trucks owned by the company.
     * @param avgDistance Average distance traveled by the company's trucks (in km).
     * @param truckWeight Weight of the trucks (in kg).
     * @param cargoWeight Weight of the cargo (in kg).
     */
    function addCompany(
        uint32 id,
        string memory name,
        uint32 trucks,
        uint32 avgDistance,
        uint32 truckWeight,
        uint32 cargoWeight
    ) external {
        companies.push(Company(id, name, trucks, avgDistance, truckWeight, cargoWeight));
    }

    /**
     * @notice Retrieves the details of a specific company.
     * @param index The index of the company in the array.
     * @return The company details.
     */
    function getCompany(uint256 index) external view returns (Company memory) {
        require(index < companies.length, "Invalid company index");
        return companies[index];
    }

    /**
     * @notice Returns the total number of companies in the system.
     * @return The total number of companies.
     */
    function getTotalCompanies() external view returns (uint256) {
        return companies.length;
    }
}
