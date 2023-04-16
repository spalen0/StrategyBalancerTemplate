from brownie import StrategyClonable

def main():
    with open('StrategyClonable.sol', 'w') as f:
        StrategyClonable.get_verification_info()
        f.write(StrategyClonable._flattener.flattened_source)
