interface Props {
    title: string;
}

export function Button({ title }: Props) {
    return <button className="primary">{title}</button>;
}
