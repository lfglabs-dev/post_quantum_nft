use openzeppelin::{
    token::erc721::{ERC721Component::{ERC721Metadata, HasComponent}},
    introspection::src5::SRC5Component,
};
use custom_uri::{main::custom_uri_component::InternalImpl, main::custom_uri_component};

#[starknet::interface]
trait IPostQuantum<TState> {
    fn mint(ref self: TState, id: u256);
    fn open(ref self: TState);
    fn close(ref self: TState);
}

#[starknet::interface]
trait IERC721Metadata<TState> {
    fn name(self: @TState) -> felt252;
    fn symbol(self: @TState) -> felt252;
    fn token_uri(self: @TState, tokenId: u256) -> Array<felt252>;
    fn tokenURI(self: @TState, tokenId: u256) -> Array<felt252>;
}

#[starknet::embeddable]
impl IERC721MetadataImpl<
    TContractState,
    +HasComponent<TContractState>,
    +SRC5Component::HasComponent<TContractState>,
    +custom_uri_component::HasComponent<TContractState>,
    +Drop<TContractState>
> of IERC721Metadata<TContractState> {
    fn name(self: @TContractState) -> felt252 {
        let component = HasComponent::get_component(self);
        ERC721Metadata::name(component)
    }

    fn symbol(self: @TContractState) -> felt252 {
        let component = HasComponent::get_component(self);
        ERC721Metadata::symbol(component)
    }

    fn token_uri(self: @TContractState, tokenId: u256) -> Array<felt252> {
        let component = custom_uri_component::HasComponent::get_component(self);
        component.get_base_uri()
    }

    fn tokenURI(self: @TContractState, tokenId: u256) -> Array<felt252> {
        self.token_uri(tokenId)
    }
}

#[starknet::contract]
mod PostQuantum {
    use post_quantum_nft::IPostQuantum;
    use starknet::ContractAddress;
    use starknet::{get_caller_address, get_contract_address, class_hash::ClassHash};
    use custom_uri::{interface::IInternalCustomURI, main::custom_uri_component};
    use openzeppelin::{
        account, access::ownable::OwnableComponent,
        upgrades::{UpgradeableComponent, interface::IUpgradeable},
        token::erc721::{
            ERC721Component, erc721::ERC721Component::InternalTrait as ERC721InternalTrait
        },
        introspection::{src5::SRC5Component, dual_src5::{DualCaseSRC5, DualCaseSRC5Trait}}
    };

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: custom_uri_component, storage: custom_uri, event: CustomUriEvent);

    // allow to check what interface is supported
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5CamelImpl = SRC5Component::SRC5CamelImpl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    // make it a NFT
    #[abi(embed_v0)]
    impl ERC721Impl = ERC721Component::ERC721Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC721CamelOnlyImpl = ERC721Component::ERC721CamelOnlyImpl<ContractState>;
    // allow to query name of nft collection
    #[abi(embed_v0)]
    impl IERC721MetadataImpl = super::IERC721MetadataImpl<ContractState>;

    // add an owner
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    // make it upgradable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        opened: bool,
        blacklisted: LegacyMap<ContractAddress, bool>,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        custom_uri: custom_uri_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        CustomUriEvent: custom_uri_component::Event
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, token_uri_base: Span<felt252>) {
        self.ownable.initializer(owner);
        self.erc721.initializer('Post Quantum', 'PQ');
        self.custom_uri.set_base_uri(token_uri_base);
    }

    #[external(v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable._upgrade(new_class_hash);
        }
    }

    #[external(v0)]
    impl PostQuantumImpl of super::IPostQuantum<ContractState> {
        // id is specified to save gas on storage and allow for multicalls on mint
        fn mint(ref self: ContractState, id: u256) {
            let caller = get_caller_address();
            assert(!self.blacklisted.read(caller), 'You can only mint once');
            assert(self.opened.read(), 'Mint is closed');
            self.erc721._mint(caller, id);
            self.blacklisted.write(caller, true);
        }

        fn open(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.opened.write(true);
        }

        fn close(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.opened.write(false);
        }
    }
}

#[cfg(test)]
mod tests {
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use starknet::{
        testing::set_contract_address, class_hash::Felt252TryIntoClassHash, ContractAddress,
        SyscallResultTrait
    };
    use super::{IPostQuantumDispatcher, IPostQuantumDispatcherTrait};
    use super::IPostQuantum;
    use super::PostQuantum;

    fn deploy(calldata: Array<felt252>) -> ContractAddress {
        let (address, _) = starknet::deploy_syscall(
            PostQuantum::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), false
        )
            .unwrap_syscall();
        address
    }

    #[test]
    #[available_gas(2000000000)]
    fn test_normal_mint() {
        let admin: ContractAddress = 0x123.try_into().unwrap();
        let user: ContractAddress = 0x456.try_into().unwrap();
        set_contract_address(admin);
        let post_quantum = IPostQuantumDispatcher {
            contract_address: deploy(array![admin.into()])
        };
        post_quantum.open();
        set_contract_address(user);

        // mint nft with id 1
        post_quantum.mint(1);
    }

    #[test]
    #[available_gas(2000000000)]
    #[should_panic(expected: ('Mint is closed', 'ENTRYPOINT_FAILED'))]
    fn test_closed_mint() {
        let admin: ContractAddress = 0x123.try_into().unwrap();
        let user: ContractAddress = 0x456.try_into().unwrap();
        let post_quantum = IPostQuantumDispatcher {
            contract_address: deploy(array![admin.into()])
        };
        set_contract_address(user);
        // mint nft with id 1
        post_quantum.mint(1);
    }

    #[test]
    #[available_gas(2000000000)]
    #[should_panic(expected: ('You can only mint once', 'ENTRYPOINT_FAILED'))]
    fn test_double_mint() {
        let admin: ContractAddress = 0x123.try_into().unwrap();
        let user: ContractAddress = 0x456.try_into().unwrap();
        set_contract_address(admin);
        let post_quantum = IPostQuantumDispatcher {
            contract_address: deploy(array![admin.into()])
        };
        post_quantum.open();
        set_contract_address(user);

        // mint nft with id 1
        post_quantum.mint(1);
        // same with 2 (should fail)
        post_quantum.mint(2);
    }
}
