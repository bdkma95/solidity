pragma solidity ^0.6.0;

contract voting {
    
    uint256 public Arsenal;
    uint256 public Juventus;
    uint256 public Liverpool;
    uint256 public RealMadrid;
    uint256 public Chelsea;
    uint256 public InterMilan;
    uint256 public ACMilan;
    uint256 public Barcelona;
    uint256 public Manchester;
    uint256 public Tottenham;
    
    function voteArsenal() public {
       Arsenal++; 
    }
    
    function voteJuventus() public {
        Juventus++;
    }
    
    function voteLiverpool() public {
        Liverpool++;
    }
    
    function voteRealMadrid() public {
        RealMadrid++;
    }
    
    function voteChelsea() public {
        Chelsea++;
    }
    
    function voteInterMilan() public {
        InterMilan++;
    }
    
    function voteACMilan() public {
        ACMilan++;
    }
    
    function voteBarcelona() public {
        Barcelona++;
    }
    
    function voteManchester() public {
        Manchester++;
    }
    
    function voteTottenham() public {
        Tottenham++;
    }
}
